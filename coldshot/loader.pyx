"""Module providing a Numpy-based loader for coldshot profiles"""
import os, urllib, sys, mmap, logging
from . import profiler
from coldshot cimport *
log = logging.getLogger( __name__ )

__all__ = ("Loader",)

cdef class MappedFile:
    """Memory-mapped file used for scanning large data-files"""
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
    """Particular mapped file which loads our callsfile data-structures"""
    cdef call_info * records 
    def get_pointer( self, mm ):
        cdef mmap_object * c_level
        c_level = <mmap_object *>mm
        self.records = <call_info *>(c_level[0].data)
        self.record_count = self.filesize // sizeof( call_info )
    def __iter__( self ):
        return CallsIterator( self )
        
cdef class CallsIterator:
    """Provide python-level iteration over a CallsFile"""
    cdef CallsFile records
    cdef long position
    def __cinit__( self, records ):
        self.records = records 
        self.position = 0
    def __next__( self ):
        if self.position < self.records.record_count:
            result = <object>(self.records.records[self.position])
            self.position += 1
            return result 
        raise StopIteration( self.position )
    
cdef class FunctionCallInfo:
    """Tracks information related to a single Function call (stack frame)"""
    cdef FunctionInfo function 
    cdef uint32_t start 
    cdef uint16_t last_line 
    cdef uint32_t last_line_time
    def __cinit__( self, FunctionInfo function, uint32_t start ):
        self.function = function 
        self.start = start 
        self.last_line = function.line
        self.last_line_time = start 
    cdef public uint32_t record_stop( self, uint32_t stop ):
        cdef uint32_t delta = stop - self.start 
        self.function.record_call(self.start)
        self.function.record_time_spent( delta )
        return delta
    cdef public uint32_t record_stop_child( self, uint32_t delta, uint32_t child ):
        """Child has exited, record time spent in the child"""
        self.function.record_time_spent_child( child, delta )
    cdef record_line( self, uint16_t new_line, uint32_t stop, int exit ):
        """Record time spent on a given line"""
        cdef FunctionLineInfo current = self.function.line_map.get( self.last_line, None )
        cdef uint32_t delta = stop-self.last_line_time
        if current is None:
            self.function.line_map[self.last_line] = current = FunctionLineInfo( self.last_line )
        current.add_time( delta, exit )
        self.last_line = new_line 
        self.last_line_time = stop 
        return 

cdef public class FunctionLineInfo [object Coldshot_FunctionLineInfo, type Coldshot_FunctionLineInfo_Type]:
    """Timing of a single line within a function"""
    cdef public uint16_t line 
    cdef public uint32_t time 
    cdef public uint32_t calls
    def __cinit__( self, uint16_t line ):
        self.line = line 
        self.time = 0
        self.calls = 0
    cdef add_time( self, uint32_t delta, int exit ):
        self.time += delta 
        if not exit:
            self.calls += 1
    def __repr__( self ):
        return b'Line %s: %s %.4fs'%( self.line, self.calls, self.time, )
    
cdef public class FileInfo [object Coldshot_FileInfo, type Coldshot_FileInfo_Type]:
    """Referenced by functions which declare the same file
    
    All built-in functions currently declare the same file number (0), so all 
    built-ins will appear to come from a single file.
    """
    cdef public object filename 
    cdef public object directory
    cdef public object path 
    cdef uint16_t fileno 
    def __cinit__( self, path, fileno ):
        self.path = path
        self.directory, self.filename = os.path.split( path )
        self.fileno = fileno 
    def __unicode__( self ):
        return '<%s for %s>'%( self.__class__.__name__, self.filename )
    __repr__ = __unicode__
        
cdef public class FunctionInfo [object Coldshot_FunctionInfo, type Coldshot_FunctionInfo_Type]:
    """Represents call/trace information for a single function
    
    Attributes of note:
    
        key -- ID/Key used in the trace to identify this function
        module -- name of the module and class (x.y.z)
        name -- name of the function/method
        file -- FileInfo for the module, note: builtins all use the same FileInfo
        line -- line on which the function begins 
        loader -- reference to the loader which created us...
        
        calls -- count of calls on the function 
        time -- cumulative time spent in the function
        child_time -- cumulative time spent in children
        line_map -- line: FunctionLineInfo mapping for each line executed
        child_map -- child_id: cumulative-time for each called child...
        
        first_timestamp -- timestamp of the first call to the function
        last_timestamp -- timestamp of the last call to the function
    
    All times/timestamps are stored in the original profiler units.
    """
    cdef public uint32_t key
    cdef public str module 
    cdef public str name 
    cdef public FileInfo file
    cdef public uint16_t line
    
    cdef public long calls 
    cdef public long child_time
    cdef public long time
    
    cdef public long first_timestamp
    cdef public long last_timestamp
    
    cdef public object line_map 
    cdef public object child_map
    cdef public object loader
    
    def __cinit__( self, uint32_t key, str module, str name, FileInfo file, uint16_t line, object loader ):
        """Initialize the FunctionInfo instance"""
        self.key = key
        self.loader = loader
        self.module = module 
        self.name = name 
        self.file = file
        self.line = line
        
        self.line_map = {}
        self.child_map = {}
        
        self.calls = 0
        self.child_time = 0
        self.first_timestamp = 0
        self.last_timestamp = 0
    # external data-API showing seconds 
    @property 
    def local( self ):
        return (self.time - self.child_time) * self.loader.timer_unit
    @property 
    def empty( self ):
        """Calculate local time as a fraction of total time"""
        return (self.time - self.child_time)/float( self.time )
    @property 
    def cumulative( self ):
        return self.time * self.loader.timer_unit
    @property 
    def localPer( self ):
        return (
            (self.time - self.child_time) * self.loader.timer_unit /
            (self.calls or 1)
        )
    @property 
    def cumulativePer( self ):
        return (
            (self.time * self.loader.timer_unit) / 
            (self.calls or 1)
        )
    @property 
    def lineno( self ):
        return self.line 
    @property 
    def filename( self ):
        return self.file.filename 
    @property 
    def directory( self ):
        return self.file.directory 
    @property
    def parents( self ):
        """Retrieve those functions which directly call me"""
        return self.loader.parents_of(self)
    @property
    def sorted_children( self ):
        """Retrieve our children records from our loader in time-sorted order
        
        returns [(cumtime,otherfunc), ... ] for all of our called children
        """
        children = [(v,self.loader.functions.get(k)) for (k,v) in self.child_map.items() if k != self.key]
        children.sort()
        return children
    @property 
    def children( self ):
        return [x[1] for x in self.sorted_children]
    def child_cumulative_time( self, other ):
        """Return cumulative time spent in other as a fraction of our cumulative time"""
        return self.child_map.get(other.key, 0)/float( self.time or 1 )

        
    # Internal APIs for Loader
    cdef record_call( self, uint32_t timestamp ):
        """Increment our internal call counter and first/last timestamp"""
        self.calls += 1
        if not self.first_timestamp:
            self.first_timestamp = timestamp
        self.last_timestamp = timestamp
    cdef record_time_spent( self, uint32_t delta ):
        """Record total time spent in the function (cumtime)"""
        self.time += delta 
    cdef record_time_spent_child( self, uint32_t child, uint32_t delta ):
        """Record time spent in a given child function"""
        cdef long current
        if child != self.key:
            # we don't consider time in ourselves to be a child...
            self.child_time += delta 
        current = self.child_map.get( child, 0 )
        self.child_map[child] = current + delta
    
    def __repr__( self ):
        return '<%s %s:%s %s:%ss>'%(
            self.__class__.__name__,
            self.module,
            self.name,
            self.calls,
            self.cumulative,
        )

cdef class ThreadStack:
    cdef uint16_t thread 
    cdef list function_stack # list of FunctionCallInfo instances 
    cdef long context_switches
    cdef uint32_t start 
    cdef uint32_t stop
    cdef Loader loader
    def __cinit__( self, uint16_t thread, FunctionInfo root, uint32_t timestamp, Loader loader ):
        self.thread = thread
        self.context_switches = 0
        self.loader = loader
        self.function_stack = []
        self.start = timestamp 
        self.stop = timestamp
        self.push( root, timestamp )
    
    @property 
    def cumulative( self ):
        """Return thread duration in seconds"""
        return (self.stop - self.start)*self.loader.timer_unit
    
    cdef record_context_switch( self, timestamp ):
        self.context_switches += 1
    cdef pop( self, uint32_t timestamp ):
        """Pop a single record from the stack at given timestamp"""
        cdef FunctionCallInfo call_info 
        cdef uint32_t current_function 
        
        call_info = <FunctionCallInfo>(self.function_stack[-1])
        call_info.record_line( call_info.function.line, timestamp, 0 )
        current_function = call_info.function.key 
        child_delta = call_info.record_stop( timestamp )
        self.stop = timestamp
        
        del self.function_stack[-1]
        if self.function_stack:
            call_info = self.function_stack[-1]
            # child is current_function...
            call_info.record_stop_child( child_delta, current_function )
    cdef pop_all( self, timestamp ):
        """Pop all non-root records"""
        while len(self.function_stack):
            self.pop( timestamp )
    cdef push( self, function_info, timestamp ):
        """Push a new record onto the function stack"""
        call_info = FunctionCallInfo( function_info, timestamp )
        self.function_stack.append( call_info )
    
def byteswap_16( input ):
    return swap_16( input )
def byteswap_32( input ):
    return swap_32( input )
        
cdef uint16_t swap_16( uint16_t input ):
    """Byte-swap a 16-bit integer"""
    cdef uint16_t output 
    cdef uint16_t low_mask = 0x00ff 
    cdef uint16_t high_mask = 0xff00
    cdef uint16_t shift = 8
    output = ((input & low_mask) << shift) | ((input & high_mask) >> shift)
    return output
cdef uint32_t swap_32( uint32_t input ):
    """Byte-swap a 32-bit integer"""
    cdef uint32_t output 
    cdef uint32_t low_mask = 0x000000ff 
    cdef uint32_t low_mid_mask = 0x0000ff00
    cdef uint32_t high_mid_mask = 0x00ff0000
    cdef uint32_t high_mask = 0xff000000
    cdef uint32_t small_shift = 8
    cdef uint32_t big_shift = 24
    output = (
        (input & low_mask) << big_shift |
        (input & low_mid_mask) << small_shift | 
        (input & high_mid_mask) >> small_shift |
        (input & high_mask ) >> big_shift
    )
    return output

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
    
    cdef public bint bigendian
    cdef public bint swapendian
    cdef public int version 
    cdef public double timer_unit
    
    cdef public dict files
    cdef public dict file_names
    cdef public dict functions 
    cdef public dict function_names
    
    cdef public FunctionInfo root
    
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
        self.bigendian = False 
        self.swapendian = False
        self.version = 1
        self.timer_unit = .000001
        self.root = FunctionInfo( 
            0xffffffff, '*', '*',
            self.files[0],
            0,
            self
        )

    def load( self ):
        """Scan our data-files for basic index information"""
        self.process_index( self.index_filename )
        self.process_calls( )
    def unquote( self, name ):
        """Remove quoting to get the original name"""
        return urllib.unquote( name )
    def process_index( self, index_filename ):
        """Process the plain-text index file to load our declarations"""
        for line in open(index_filename):
            line = line.strip( '\n' )
            line = line.split()
            if line[0] == 'P':
                # prefix/metadata declaration...
                for variable in line[2:]:
                    key,value = variable.split('=')
                    if key == 'bigendian':
                        self.bigendian = value == 'True'
                        if self.bigendian != (sys.byteorder == 'big'):
                            self.swapendian = True
                    elif key == 'version':
                        self.version = int(value)
                    elif key == 'timer_unit':
                        self.timer_unit = float( value )
            elif line[0] == 'F':
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
                    funcno,module,name,
                    self.files[fileno],
                    lineno,
                    self
                )
            elif line[0] == 'D':
                # data-file declaration...
                if line[1] == 'calls':
                    self.call_files.append( line[2] )
                else:
                    log.error( "Unrecognized data-file type: %s %s", line[1], line[2] )
    def process_calls( self ):
        """Process all of our call files"""
        for call_file in self.call_files:
            self.process_call_file( call_file )
    def process_call_file( self, calls_filename ):
        """Process a CallsFile to extract basic cProfile-like information
        
        Fills in the FunctionInfo members in self.functions with the 
        basic metadata from doing a linear scan of all calls in the calls file
        
        The index *must* have been loaded or we will raise KeyError when we 
        attempt to find our FunctionInfo records
        """
        # State-lookup speedups.
        cdef uint16_t current_thread = 0# whether we need to load new thread info
        cdef uint32_t current_function = 0 # the function currently being processed...
        cdef ThreadStack stack # current stack (thread)
        cdef FunctionInfo function_info # current function 
        cdef FunctionCallInfo call_info # temp for function being called...
        cdef FunctionCallInfo root_call
        
        cdef uint32_t flag_mask = 0xff000000
        cdef uint32_t function_mask = 0x00ffffff
        cdef uint32_t flag_shift = 24
        
        # incoming record information
        cdef uint16_t thread = 0
        cdef uint32_t function = 0
        cdef uint32_t timestamp = 0
        cdef uint32_t flags = 0
        cdef uint16_t line = 0

        # Canonical state storage...
        cdef dict stacks = {}
        
        # The source data...
        cdef CallsFile calls_data = CallsFile( calls_filename )
        
        function_info = None
        
        current_thread = 0
        
        for i in range( calls_data.record_count ):
            thread = calls_data.records[i].thread
            if self.swapendian:
                thread = swap_16( thread )
            function = calls_data.records[i].function
            if self.swapendian:
                function = swap_32( function )
            flags = (function & flag_mask) >> flag_shift
            function = function & function_mask
            
            timestamp = calls_data.records[i].timestamp
            if self.swapendian:
                timestamp = swap_32( timestamp )
            line = calls_data.records[i].line
            if self.swapendian:
                line = swap_16( line )
            
            if thread != current_thread:
                # we are following a thread context switch, 
                # we should *likely* track that somewhere...
                stack = stacks.get( thread )
                if stack is None:
                    stacks[thread] = stack = ThreadStack( thread, self.root, timestamp, self )
                else:
                    stack.record_context_switch(timestamp)
                current_thread = thread
            
            if function != current_function or function_info is None:
                # we have switched functions, need to get the new function's record...
                function_info = <FunctionInfo>self.functions[function]
                current_function = function
                if self.root is None:
                    self.root = function_info
                
            if flags == 1: # call...
                stack.push( function_info, timestamp )
            elif flags == 2: # return 
                # TODO: suppress start-of-func lines, as they are not really 
                # telling us anything about the individual lines...
                stack.pop( timestamp )
            elif flags == 0: # line...
                # we know current function exists, but there's no guarantee that the function 
                # was called within the profile operation (it is know that there will be times 
                # it was not, in fact), so we need to pull a line-specific stack for this...
                call_info = stack.function_stack[-1]
                call_info.record_line( line, timestamp, 0 )
        for stack in stacks.values():
            stack.pop_all(timestamp)
        calls_data.close()

    def parents_of( self, FunctionInfo child ):
        """Retrieve those functions who are parents of functioninfo"""
        cdef FunctionInfo possible 
        result = []
        for possible in self.functions.itervalues():
            if child.key in possible.child_map:
                result.append( possible )
        return result 
    def rows( self ):
        """Produce the set of all rows"""
        return self.functions.values()
    
