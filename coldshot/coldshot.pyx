"""Coldshot, a Hotshot replacement in Cython"""
from cpython cimport PY_LONG_LONG
import urllib 

cdef extern from "stdio.h":
    ctypedef void FILE
    FILE *fopen(char *path, char *mode)
    size_t fwrite(void *ptr, size_t size, size_t nmemb, FILE *stream)
    int fclose(FILE *fp)

cdef extern from 'Python.h':
    int PyTrace_C_CALL
    int PyTrace_C_RETURN
    int PyTrace_LINE
    
    ctypedef struct PyCodeObject:
        void * co_filename
        void * co_name
        int co_firstlineno
    
    ctypedef struct PyThreadState:
        long thread_id
    
cdef extern from 'frameobject.h':
    ctypedef struct PyFrameObject:
        PyCodeObject *f_code
        PyThreadState *f_tstate
        int f_lineno

# timers, from line_profiler
cdef extern from "timers.h":
    PY_LONG_LONG hpTimer()
    double hpTimerUnit()

# pretty much the same code as line-profiler
cdef extern from 'lowlevel.h':
    void coldshot_set_trace( void * callback, object arg )
    void coldshot_unset_trace()
    void * format_long_long(PY_LONG_LONG to_encode)

cdef struct LineTiming:
    short int file
    short int line 
    PY_LONG_LONG timestamp
    
def timer():
    return hpTimer()

cdef class TestWrite:
    cdef FILE * fd
    cdef int long_long_size
    def __cinit__( self, filename ):
        cdef FILE * fd 
        fd = fopen( filename, 'w' )
        self.fd = fd
        self.long_long_size = sizeof( PY_LONG_LONG )
    def test_write( self ):
        # addressof( converted )
        cdef PY_LONG_LONG temp 
        cdef void * formatted
        temp = 22222222223444
        written = fwrite( &temp, self.long_long_size, 1, self.fd  )
        print 'wrote', written
    def close( self ):
        fclose( self.fd )
    
cdef class Writer:
    cdef int version
    cdef object output
    def __cinit__( self, output, version=1 ):
        self.output = output
        self.version = version
    
    cdef clean_name( self, str name ):
        return urllib.quote( name )
    
    def prefix( self ):
        return self.write_prefix()
    cdef write_prefix( self ):
        return self.output( 'COLDSHOT ASCII v%i\n'%( self.version, ) )
    
    def file( self, int fileno, str filename ):
        return self.write_file( fileno, filename )
    cdef write_file( self, int fileno, str filename ):
        return self.output( 'F %hi %s\n'%( fileno, self.clean_name(filename) ))
    
    def func( self, fileno, lineno, name ):
        return self.write_func( fileno, lineno, name )
    cdef write_func( self, int fileno, int lineno, str name ):
        return self.output( 'f %hi %hi %s\n'%( fileno, lineno, self.clean_name(name) ))
    
    def call( self, fileno, lineno, ts ):
        return self.write_call( fileno, lineno, ts )
    cdef write_call( self, int fileno, int lineno, float ts ):
        return self.output( 'C %hi %hi %llu\n'%( fileno, lineno, ts ) )
    
    def return_( self, ts ):
        return self.write_return( ts )
    cdef write_return( self, float ts ):
        return self.output( 'R %llu\n'%( ts, ))
    
    def line( self, lineno, ts ):
        return self.write_line( lineno, ts )
    cdef write_line( self, int lineno, float ts ):
        return self.output( 'L %hi %llu\n'%( lineno, ts ))

cdef class Profiler:
    cdef dict files
    cdef int next_file
    cdef set functions
    cdef Writer writer
    cdef PY_LONG_LONG internal_time
    cdef PY_LONG_LONG last_time
    def __init__( self, file, version=1 ):
        self.writer = Writer( file.write, version )
        self.files = {}
        self.functions = set()
        self.next_file = 1
    cdef file_to_number( self, PyCodeObject code ):
        filename = <object>(code.co_filename)
        if filename in self.files:
            return self.files[filename]
        # TODO: incref
        self.files[filename] = result = self.next_file 
        self.next_file += 1
        self.writer.write_file( result, filename )
        return result 
        
    cdef write_call( self, PyFrameObject frame ):
        cdef PyCodeObject code
        ts = self.delta()
        code = frame.f_code[0]
        fileno = self.file_to_number( code )
        lineno = code.co_firstlineno
        key = (fileno,lineno)
        if key not in self.functions:
            self.functions.add( key )
            self.writer.write_func( fileno, lineno, <object>(code.co_name) )
        self.writer.write_call( fileno, lineno, ts)
        self.discount()
    cdef write_return( self, PyFrameObject frame ):
        ts = self.delta()
        self.writer.write_return( ts )
        self.discount()
    cdef write_line( self, PyFrameObject frame ):
        ts = self.delta()
        self.writer.write_line( frame.f_lineno, ts )
        self.discount()
    
    cdef delta( self ):
        """Calculate the delta since the last call to hpTimer(), store new value"""
        cdef PY_LONG_LONG current
        cdef PY_LONG_LONG delta
        current = hpTimer()
        delta = current - self.last_time
        self.internal_time += delta 
        self.last_time = current
        return self.internal_time
    cdef discount( self ):
        """Discount the time since the last call to hpTimer()"""
        self.last_time = hpTimer()
        return self.internal_time
    
    def start( self ):
        """Install this profiler as the trace function for the interpreter"""
        coldshot_set_trace( <void *>callback, self )
        self.internal_time = 0
        self.discount()
    def stop( self ):
        """Remove the currently installed profiler (even if it is not us)"""
        coldshot_unset_trace( )

cdef callback( Profiler instance, PyFrameObject frame, int what, object arg ):
    if what == PyTrace_LINE:
        instance.write_line( frame )
    elif what == PyTrace_C_CALL:
        instance.write_call( frame )
    elif what == PyTrace_C_RETURN:
        instance.write_return( frame )
    instance.discount()
