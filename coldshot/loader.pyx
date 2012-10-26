"""Module providing a Numpy-based loader for coldshot profiles"""
import os, urllib, sys, mmap, logging
from . import profiler
from coldshot cimport *
log = logging.getLogger( __name__ )

__all__ = ("Loader",)

cdef class MappedFile:
    cdef object filename 
    cdef long filesize
    cdef object fh 
    cdef object mm
    cdef public long record_count
    def __cinit__( self, filename ):
        self.filename = filename
        self.fh = open( filename, 'rb' )
        self.filesize = os.stat( filename ).st_size 
        self.mm = mmap.mmap( self.fh.fileno(), self.filesize, prot=mmap.PROT_READ )
        self.get_pointer( self.mm )
    def close( self ):
        self.mm.close()
        self.fh.close()
    
cdef class CallsFile(MappedFile):
    cdef call_info * records 
    def get_pointer( self, mm ):
        cdef mmap_object * c_level
        c_level = <mmap_object *>mm
        self.records = <call_info *>(c_level[0].data)
        self.record_count = self.filesize // sizeof( call_info )
cdef class LinesFile(MappedFile):
    cdef line_info * records
    def get_pointer( self, mm ):
        cdef mmap_object * c_level
        c_level = <mmap_object *>mm
        self.records = <line_info *>(c_level[0].data)
        self.record_count = self.filesize // sizeof( line_info )
    
def test_mmap( filename ):
    """Test mmaping a file into call_info structures"""
    cf = CallsFile( filename )
    for i in range( cf.record_count ):
        print cf.records[i].thread
    cf.close()

cdef class FunctionCallInfo:
    cdef FunctionInfo function 
    cdef uint32_t start 
    def __cinit__( self, FunctionInfo function, uint32_t start ):
        self.function = function 
        self.start = start 
        function.record_call()
    cdef public uint32_t record_stop( self, uint32_t stop ):
        cdef uint32_t delta = stop - self.start 
        self.function.record_time_spent( delta )
        return delta
cdef class ThreadTimeInfo:
    cdef uint16_t thread 
    cdef uint32_t last_ts 
    cdef object last_record
    def __cinit__( self, uint16_t thread, uint32_t last_ts ):
        self.thread = thread 
        self.last_ts = last_ts
    def line_ts( self, uint32_t new_ts ):
        cdef uint32_t delta = new_ts - self.last_ts
        self.last_ts = new_ts 
        return delta 
    cdef set_last_line( self, last_record ):
        self.last_record = last_record

cdef class ChildCall:
    cdef uint16_t id
    cdef uint32_t time
    def __cinit__( self, uint16_t id, uint32_t time ):
        self.id = id 
        self.time = time 

cdef public class FunctionLineInfo [object Coldshot_FunctionLineInfo, type Coldshot_FunctionLineInfo_Type]:
    cdef public uint16_t lineno 
    cdef public uint32_t time 
    cdef public uint32_t count
    def __cinit__( self, uint16_t lineno ):
        self.lineno = lineno 
        self.time = 0
        self.count = 0
    cdef add_time( self, uint32_t delta ):
        self.time += delta 
        self.count += 1
    
cdef public class FileInfo [object Coldshot_FileInfo, type Coldshot_FileInfo_Type]:
    cdef object filename 
    cdef uint16_t fileno 
    def __cinit__( self, filename, fileno ):
        self.filename = filename 
        self.fileno = fileno 
    def __unicode__( self ):
        return '<%s for %s>'%( self.__class__.__name__, self.filename )
    __repr__ = __unicode__
        
cdef public class FunctionInfo [object Coldshot_FunctionInfo, type Coldshot_FunctionInfo_Type]:
    """Represents call/trace information for a single function
    
    Attributes of note:
    
        id -- ID used in the trace 
        module -- name of the module and class (x.y.z)
        name -- name of the function/method
        file -- FileInfo for the module, note: builtins all use the same FileInfo
        line -- line on which the function begins 
        
        calls -- count of calls on the function 
        time -- cumulative time spent in the function
        line_map -- lineno: FunctionLineInfo mapping for each line executed
    """
    cdef public short int id
    cdef public str module 
    cdef public str name 
    cdef public FileInfo file
    cdef public short int line
    
    cdef public long calls 
    cdef public long recursive_calls # TODO
    cdef public long local_time
    cdef public long time
    
    cdef public object line_map 
    cdef public list children # TODO
    
    def __cinit__( self, short int id, str module, str name, FileInfo file, short int line ):
        self.id = id
        self.module = module 
        self.name = name 
        self.file = file
        self.line = line
        self.calls = 0
        self.recursive_calls = 0
        
        self.line_map = {}
        self.children = []
    
    cdef record_call( self ):
        """Increment our internal call counter"""
        self.calls += 1
    cdef record_time_spent( self, uint32_t delta ):
        """Record total time spent in the function (cumtime)"""
        self.time += delta 
#    cdef record_time_spent_child( self, short int child, uint32_t delta ):
#        self.time += delta 
#        # Yes, a linear scan, but on a very short list...
#        for my_child in self.children:
#            if my_child.id == child:
#                my_child.time += delta 
#        self.children.append( ChildCall( child, delta ))
    def info_for_line( self, uint16_t line ):
        """Get/create FunctionLineInfo for given line"""
        line_object = self.line_map.get( line )
        if line_object is None:
            self.line_map[line] = line_object = FunctionLineInfo( line )
        return line_object
    def __unicode__( self ):
        seconds = self.time / float( 1000000 )
        return u'%s % 5i % 5.4fs % 5.4fs'%(
            self.name.ljust(30),
            self.calls,
            seconds,
            seconds/self.calls
        )
    def __repr__( self ):
        return '<%s %s:%s %s:%ss>'%(
            self.__class__.__name__,
            self.module,
            self.name,
            self.calls,
            self.time/float(1000000),
        )

cdef public class Loader [object Coldshot_Loader, type Coldshot_Loader_Type ]:
    """Loader for Coldshot profiles
    
    Attributes of note:
    
        files -- map ID: FileInfo objects 
        file_names -- map filename: ID 
        functions -- map ID: FunctionInfo objects 
        function_names -- map function-name: ID
    """
    cdef public object directory
    
    cdef public object index_filename
    cdef public list call_files 
    cdef public list line_files 
    
    cdef public dict files
    cdef public dict file_names
    cdef public dict functions 
    cdef public dict function_names
    
    def __cinit__( self, directory ):
        self.directory = directory
        self.index_filename = os.path.join( directory, profiler.Profiler.INDEX_FILENAME )
        self.call_files = []
        self.line_files = []
        self.files = {}
        self.file_names = {}
        self.functions = {}
        self.function_names = {}
        self.file_names['__builtin__'] = self.files[0] = FileInfo( '__builtin__', 0 )

    def load( self ):
        """Scan our data-files for basic index information"""
        self.process_index( self.index_filename )
        for call_file in self.call_files:
            self.process_calls( call_file )
        for line_file in self.line_files:
            self.process_lines( line_file )
    def unquote( self, name ):
        """Remove quoting to get the original name"""
        return urllib.unquote( name )
    def process_index( self, index_filename ):
        """Process the plain-text index file to load our declarations"""
        for line in open(index_filename):
            line = line.strip( '\n' )
            line = line.split()
            if line[0] == 'F':
                # code-file declaration
                fileno,filename = line[1:3]
                fileno = int(fileno)
                filename = self.unquote( filename )
                self.file_names[filename] = self.files[fileno] = FileInfo( filename, fileno )
            elif line[0] == 'f':
                # function/built-in declaration
                try:
                    funcno,fileno,lineno,module,name = line[1:6]
                except Exception as err:
                    err.args += (line,)
                    raise
                funcno,fileno,lineno = int(funcno),int(fileno),int(lineno)
                
                module = self.unquote( module )
                name = self.unquote( name )
                self.function_names[ (module,name) ] = self.functions[ funcno ] = FunctionInfo( 
                    funcno,module,name,self.files[fileno],lineno 
                )
            elif line[0] == 'D':
                # data-file declaration...
                if line[1] == 'calls':
                    self.call_files.append( line[2] )
                elif line[1] == 'lines':
                    self.line_files.append( line[2] )
                else:
                    log.error( "Unrecognized data-file type: %s %s", line[1], line[2] )
    def process_calls( self, calls_filename ):
        """Process a CallsFile to extract basic cProfile-like information
        
        Fills in the FunctionInfo members in self.functions with the 
        basic metadata from doing a linear scan of all calls in the calls file
        
        The index *must* have been loaded or we will raise KeyError when we 
        attempt to find our FunctionInfo records
        """
        cdef uint16_t current_thread
        cdef uint16_t thread
        cdef uint32_t timestamp
        cdef dict stacks
        cdef list stack 
        cdef FunctionInfo func 
        cdef CallsFile calls_data = CallsFile( calls_filename )
        
        current_thread = 0
        stacks = {}
        for i in range( calls_data.record_count ):
            thread = calls_data.records[i].thread
            timestamp = calls_data.records[i].timestamp
            
            if thread != current_thread:
                stack = stacks.get( thread )
                if stack is None:
                    stacks[thread] = stack = []
                current_thread = thread
            
            if calls_data.records[i].stack_depth >= 0:
                # is a call...
                func = <FunctionInfo>self.functions[calls_data.records[i].function]
                stack.append( FunctionCallInfo( func, timestamp ) )
            else:
                # is a return
                (<FunctionCallInfo>(stack[-1])).record_stop( timestamp )
                del stack[-1]
        calls_data.close()
    
    def process_lines( self, lines_filename ):
        """Do initial processing of a lines file to produce FileInfo records"""
        cdef LinesFile lines_data = LinesFile( lines_filename )
        cdef object thread_object
        cdef ThreadTimeInfo thread_info
        cdef FunctionInfo function_info 
        cdef FunctionLineInfo line_info_c
        
        cdef uint16_t current_thread
        cdef uint16_t thread
        cdef uint32_t timestamp
        cdef uint32_t delta
        
        cdef dict threads = {}
        current_thread = 0
        
        for i in range( lines_data.record_count ):
            thread = lines_data.records[i].thread
            timestamp = lines_data.records[i].timestamp
            if thread != current_thread:
                thread_object  = threads.get( thread )
                if thread_object is None:
                    thread_info = ThreadTimeInfo( thread, timestamp )
                    threads[ thread ] = thread_info
                else:
                    thread_info = <ThreadTimeInfo>thread_object
            if i > 0:
                assert thread_info.last_record
                line_info_c = (<FunctionLineInfo>(thread_info.last_record))
                delta = thread_info.line_ts( timestamp )
                line_info_c.add_time( delta )
            function_info = <FunctionInfo>(self.functions[ lines_data.records[i].funcno ])
            thread_info.set_last_line( function_info.info_for_line( lines_data.records[i].lineno ) )
    
