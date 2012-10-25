"""Module providing a Numpy-based loader for coldshot profiles"""
import os, urllib, sys
from . import profiler
import os, mmap
from coldshot cimport *

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
#cdef class LinesFile(MappedFile):
#    cdef line_info * records
#    def get_pointer( self, mm ):
#        cdef mmap_object c_level
#        c_level = <mmap_object>mm
#        self.records = <line_info *>(c_level.data)
#        self.record_count = self.filesize // sizeof( line_info )
    
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

cdef class ChildCall:
    cdef short int id
    cdef uint32_t time
    def __cinit__( self, short int id, uint32_t time ):
        self.id = id 
        self.time = time 
    
cdef class FunctionInfo:
    cdef public short int id
    cdef public str name 
    cdef public short int file 
    cdef public short int line
    cdef public list children
    
    cdef public long calls 
    cdef public long recursive_calls
    cdef public long local_time
    cdef public long time
    
    def __cinit__( self, short int id, str name, short int file, short int line ):
        self.id = id
        self.name = name 
        self.file = file
        self.line = line
        self.calls = 0
        self.recursive_calls = 0
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
    def __unicode__( self ):
        seconds = self.time / float( 1000000 )
        return u'%s %s:%s calls=%s cumtime=%ss avgtime=%s'%(
            self.name,
            self.file,
            self.line,
            self.calls,
            seconds,
            seconds/self.calls
        )

cdef class Loader:
    """Loader that can load a Coldshot profile"""
    cdef public object directory
    
    cdef public object index_filename
    cdef public object calls_filename
    cdef public object lines_filename
    
    cdef public object calls_data
    cdef public object lines_data
    
    cdef public dict files
    cdef public dict file_names
    cdef public dict functions 
    cdef public dict function_names
    
    def __cinit__( self, directory ):
        self.directory = directory
        self.index_filename = os.path.join( directory, profiler.Writer.INDEX_FILENAME )
        self.calls_filename = os.path.join( directory, profiler.Writer.CALLS_FILENAME )
        self.lines_filename = os.path.join( directory, profiler.Writer.LINES_FILENAME )
        
        self.calls_data = CallsFile( self.calls_filename )
        
        self.files = {}
        self.file_names = {}
        self.functions = {}
        self.function_names = {}

        self.process_index( self.index_filename )
        self.process_calls( self.calls_data )
    def load_name( self, name ):
        return urllib.unquote( name )
    def process_index( self, index_filename ):
        for line in open(index_filename):
            line = line.strip( '\n' )
            line = line.split()
            if line[0] == 'F':
                fileno,filename = line[1:3]
                fileno = int(fileno)
                self.files[fileno] = self.load_name( filename )
                self.file_names[filename] = fileno
            elif line[0] == 'f':
                funcno,fileno,lineno,name = line[1:5]
                funcno,fileno,lineno = int(funcno),int(fileno),int(lineno)
                name = self.load_name( name )
                self.functions[ funcno ] = FunctionInfo( funcno,name,fileno,lineno )
                self.function_names[ name ] = funcno
    def process_calls( self, CallsFile calls_data ):
        """Process a calls filename"""
        cdef uint16_t current_thread
        cdef uint16_t thread
        cdef uint32_t timestamp
        cdef dict stacks
        cdef list stack 
        cdef FunctionInfo func 
        
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
    def print_report( self ):
        for funcinfo in self.functions.values():
            print unicode( funcinfo )

def main():
    loader = Loader( sys.argv[1] )
    loader.print_report()
    
