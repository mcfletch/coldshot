"""Coldshot, a Hotshot replacement in Cython"""
from cpython cimport PY_LONG_LONG
import urllib 

cdef extern from "frameobject.h":
    ctypedef int (*Py_tracefunc)(object self, PyFrameObject *py_frame, int what, object arg)

cdef extern from "stdio.h":
    ctypedef void FILE
    FILE *fopen(char *path, char *mode)
    size_t fwrite(void *ptr, size_t size, size_t nmemb, FILE *stream)
    int fclose(FILE *fp)
    int fflush(FILE *fp)

cdef extern from 'Python.h':
    int PyTrace_C_CALL
    int PyTrace_C_RETURN
    int PyTrace_CALL
    int PyTrace_RETURN
    int PyTrace_LINE
    
    ctypedef struct PyCodeObject:
        void * co_filename
        void * co_name
        int co_firstlineno
    
    ctypedef struct PyThreadState:
        long thread_id
    
    cdef void PyEval_SetProfile(Py_tracefunc func, object arg)
    cdef void PyEval_SetTrace(Py_tracefunc func, object arg)
    
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
    void coldshot_unset_trace()
    void coldshot_unset_profile()

def timer():
    return hpTimer()

cdef class Writer:
    cdef FILE * fd
    cdef FILE * index
    cdef int version
    cdef object output
    cdef size_t long_long_size
    cdef size_t int_size
    cdef size_t short_size 
    cdef bytes filename 
    cdef bytes index_filename
    cdef int opened
    def __cinit__( self, filename, version=1 ):
        self.version = version
            
        self.filename = filename.encode('utf-8')
        self.index_filename = filename + '.index'.encode('utf-8')
        self.fd = self.open_file( filename )
        self.index = self.open_file( self.index_filename )
        self.opened = 1
        
        self.long_long_size = sizeof( PY_LONG_LONG )
        self.int_size = sizeof( long int )
        self.short_size = sizeof( short int )
    
    cdef FILE * open_file( self, bytes filename ):
        cdef FILE * fd 
        fd = fopen( filename, 'w' )
        if fd == NULL:
            raise IOError( "Unable to open output file: %s", filename )
        return fd
    cdef write_short( self, int out, FILE * which ):
        # assumes little-endian!
        written = fwrite( &out, 2, 1, which )
    cdef write_int( self, int out, FILE * which ):
        # assumes little-endian!
        written = fwrite( &out, 4, 1, which )
        if written != 1:
            raise RuntimeError( "Unable to write to output file" )
        
    cdef write_ll( self, PY_LONG_LONG out, FILE * which ):
        written = fwrite( &out, self.long_long_size, 1, which )
        if written != 1:
            raise RuntimeError( "Unable to write to output file" )
    cdef write_string( self, object out, FILE * which ):
        if isinstance( out, unicode ):
            out = out.encode( 'utf-8' )
        cdef char * temp = out 
        written = fwrite( temp, len(out), 1, which  )
        if written != 1:
            raise RuntimeError( "Unable to write to output file" )
    
    cdef clean_name( self, str name ):
        return urllib.quote( name )
    
    def prefix( self ):
        return self.write_prefix()
    cdef write_prefix( self ):
        message = b'COLDSHOT Binary v%s\n'%( self.version, )
        self.write_string( message, self.index)
        self.write_ll( 1, self.index )
        self.write_string( '\n', self.index )
        self.write_int( self.int_size, self.index)
        self.write_string( '\n' , self.index)
    
    def file( self, int fileno, str filename ):
        return self.write_file( fileno, filename )
    cdef write_file( self, int fileno, str filename ):
        self.write_string( 'F %d %s\n'%( fileno, self.clean_name( filename )), self.index)
    
    def func( self, fileno, lineno, name ):
        return self.write_func( fileno, lineno, name )
    cdef write_func( self, int fileno, int lineno, str name ):
        self.write_string( 
            'f %hi %hi %s\n'%( fileno, lineno, self.clean_name(name) ), 
            self.index
        )
    
    def call( self, fileno, lineno, ts ):
        return self.write_call( fileno, lineno, ts )
    cdef write_call( self, int fileno, int lineno, PY_LONG_LONG ts ):
        self.write_short( fileno, self.fd )
        self.write_short( lineno, self.fd )
        self.write_ll( ts, self.fd )
    
    def return_( self, ts ):
        return self.write_return( ts )
    cdef write_return( self, PY_LONG_LONG ts ):
        self.write_short( 0, self.fd )
        self.write_short( 0, self.fd )
        self.write_ll( ts, self.fd )
    
    def line( self, lineno, ts ):
        return self.write_line( lineno, ts )
    cdef write_line( self, int lineno, PY_LONG_LONG ts ):
        self.write_short( 0, self.fd )
        self.write_short( lineno, self.fd )
        self.write_ll( ts, self.fd )
    
    def flush( self ):
        fflush( self.fd )
        fflush( self.index )
    
    def close( self ):
        self._close()
    cdef _close( self ):
        if self.opened:
            self.opened = 0
            fclose( self.fd )
            fclose( self.index )
    def __dealloc__( self ):
        self._close()

# Numpy structure describing the format written to disk for this 
# version of the profiler...
RECORD_STRUCTURE = [
    ('fileno','<i2'),('lineno','<i2'),('timestamp','<L')
]
        
cdef class Profiler:
    cdef dict files
    cdef int next_file
    cdef set functions
    cdef Writer writer
    cdef PY_LONG_LONG internal_time
    cdef PY_LONG_LONG last_time
    def __init__( self, filename, version=1 ):
        self.writer = Writer( filename, version )
        self.writer.prefix()
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
        PyEval_SetProfile(trace_callback, self)
        PyEval_SetTrace(trace_callback, self)
        self.internal_time = 0
        self.discount()
    def stop( self ):
        """Remove the currently installed profiler (even if it is not us)"""
        coldshot_unset_profile()
        coldshot_unset_trace()
        self.writer.flush()
    
    def  __dealloc__( self ):
        if self.writer:
            self.writer.close()
    
    @property
    def filename( self ):
        return self.writer.filename 
    @property 
    def index_filename( self ):
        return self.writer.index_filename 
    

cdef int trace_callback(
    object self, 
    PyFrameObject *frame, 
    int what,
    object arg
):
    cdef Profiler profiler = <Profiler>self
    if what == PyTrace_LINE:
        print 'line'
        profiler.write_line( frame[0] )
    elif what == PyTrace_CALL:
        print 'call'
        profiler.write_call( frame[0] )
    elif what == PyTrace_RETURN:
        print 'return'
        profiler.write_return( frame[0] )
    profiler.discount()
    return 0
