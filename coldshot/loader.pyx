"""Module providing a Numpy-based loader for coldshot profiles"""
import os, urllib, sys, numpy
from . import profiler
from cpython cimport PY_LONG_LONG, PyBUF_SIMPLE
import os, mmap

__all__ = ("Loader",)

cdef extern from "stdint.h":
    ctypedef int int32_t
    ctypedef int int16_t
    ctypedef int int64_t

cdef extern from "minimalmmap.h":
    ctypedef struct mmap_object:
        void * data

cdef struct call_info:
    char rectype 
    int32_t thread 
    int32_t function 
    int64_t timestamp 
    int16_t stack_depth

cdef class MappedFile:
    cdef object filename 
    cdef long filesize
    cdef object fh 
    cdef object mm
    cdef long record_count
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

#('rectype','S1'),('thread','i4'),('function','<i4'),('timestamp','<L'),('stack_depth', '<i2'),
cdef class FunctionCallInfo:
    cdef FunctionInfo function 
    cdef PY_LONG_LONG start 
    def __cinit__( self, FunctionInfo function, PY_LONG_LONG start ):
        self.function = function 
        self.start = start 
    cdef PY_LONG_LONG record_stop( self, PY_LONG_LONG stop ):
        cdef PY_LONG_LONG delta = stop - self.start 
        self.function.record_time_spent( delta )
        return delta

cdef class ChildCall:
    cdef short int id
    cdef PY_LONG_LONG time
    def __cinit__( self, short int id, PY_LONG_LONG time ):
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
        self.children = []
    
    cdef record_time_spent( self, PY_LONG_LONG delta ):
        self.local_time += delta 
#    cdef record_time_spent_child( self, short int child, PY_LONG_LONG delta ):
#        self.time += delta 
#        # Yes, a linear scan, but on a very short list...
#        for my_child in self.children:
#            if my_child.id == child:
#                my_child.time += delta 
#        self.children.append( ChildCall( child, delta ))
    def __unicode__( self ):
        return u'%s <%s:%s> %ss'%(
            self.name,
            self.file,
            self.line,
            self.local_time / float( 1000000 ),
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
        
        self.calls_data = numpy.memmap( self.calls_filename ).view( profiler.CALLS_STRUCTURE )
        self.lines_data = numpy.memmap( self.lines_filename ).view( profiler.LINES_STRUCTURE )
        
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
    def process_calls( self, calls_data ):
        """Process a calls filename"""
        cdef int current_thread
        cdef int thread
        cdef char rectype
        cdef dict stacks
        cdef list stack 
        
        current_thread = 0
        stacks = {}
        for record in calls_data:
            rectype = record['rectype']
            thread = record['thread']
            if thread != current_thread:
                stack = self.stacks.get( thread )
                if stack is None:
                    self.stacks[thread] = stack = []
                current_thread = thread
            if rectype == b'c':
                func = self.functions[record['function']]
                stack.append( FunctionCallInfo( func, record['timestamp'] ) )
            elif rectype == b'r':
                stack[-1].record_stop( record['timestamp'])
                del stack[-1]
    def print_report( self ):
        for funcinfo in self.functions.values():
            print unicode( funcinfo )

def main():
    loader = Loader( sys.argv[1] )
    loader.print_report()
    
