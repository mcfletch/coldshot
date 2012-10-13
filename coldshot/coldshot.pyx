"""Coldshot, a Hotshot-like profiler implementation in Cython
"""
from cpython cimport PY_LONG_LONG
import urllib, os

cdef extern from "frameobject.h":
    ctypedef int (*Py_tracefunc)(object self, PyFrameObject *py_frame, int what, object arg)

cdef extern from "stdio.h":
    ctypedef void FILE
    FILE *fopen(char *path, char *mode)
    size_t fwrite(void *ptr, size_t size, size_t nmemb, FILE *stream)
    int fclose(FILE *fp)
    int fflush(FILE *fp)

cdef extern from 'Python.h':
    # TODO: need to add c-call and c-return..
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

__all__ = [
    'timer',
    'Profiler',
]
# Numpy structure describing the format written to disk for this 
# version of the profiler...
CALLS_STRUCTURE = [
    ('rectype','b1'),('thread','i4'),('fileno','<i2'),('lineno','<i2'),('timestamp','<L')
]
LINES_STRUCTURE = [
    ('thread','i4'),('fileno','<i2'),('lineno','<i2'),('timestamp','<L')
]
    
def timer():
    return hpTimer()

cdef class Writer:
    """Implements direct-to-file writing for the Profiler class
    
    Files created:
    
        index -- directory/index.profile
        lines -- directory/lines.data
        calls -- directory/calls.data
    """
    cdef public int version
    
    cdef public bytes directory
    cdef public bytes index_filename 
    cdef public bytes lines_filename
    cdef public bytes calls_filename
    
    cdef int opened
    
    cdef size_t long_long_size
    cdef size_t int_size
    cdef size_t short_size 
    
    cdef FILE * index_fd
    cdef FILE * lines_fd 
    cdef FILE * calls_fd 
    
    def __cinit__( self, directory, version=1 ):
        self.version = version
        
        if isinstance( directory, unicode ):
            directory = directory.encode( 'utf-8' )
        self.prepare_directory( directory )
        
        self.long_long_size = sizeof( PY_LONG_LONG )
        self.int_size = sizeof( long int )
        self.short_size = sizeof( short int )
    
    INDEX_FILENAME = b'index.profile'
    CALLS_FILENAME = b'calls.data'
    LINES_FILENAME = b'lines.data'
    
    def prepare_directory( self, bytes directory ):
        if not os.path.exists( directory ):
            os.makedirs( directory )
        self.directory = directory 
        self.index_filename = os.path.join( directory, self.INDEX_FILENAME )
        self.calls_filename = os.path.join( directory, self.CALLS_FILENAME )
        self.lines_filename = os.path.join( directory, self.LINES_FILENAME )
        
        self.index_fd = self.open_file( self.index_filename )
        self.lines_fd = self.open_file( self.lines_filename )
        self.calls_fd = self.open_file( self.calls_filename )
        
        self.opened = 1
    
    cdef FILE * open_file( self, bytes filename ):
        cdef FILE * fd 
        fd = fopen( filename, 'w' )
        if fd == NULL:
            raise IOError( "Unable to open output file: %s", filename )
        return fd
    cdef write_short( self, int out, FILE * which ):
        if self.opened:
            # assumes little-endian!
            written = fwrite( &out, 2, 1, which )
            if written != 1:
                raise IOError( "Unable to write to output file" )
    cdef write_long( self, long out, FILE * which ):
        if self.opened:
            # assumes little-endian!
            written = fwrite( &out, 4, 1, which )
            if written != 1:
                raise IOError( "Unable to write to output file" )
        
    cdef write_long_long( self, PY_LONG_LONG out, FILE * which ):
        if self.opened:
            written = fwrite( &out, self.long_long_size, 1, which )
            if written != 1:
                raise IOError( "Unable to write to output file" )
    cdef write_string( self, object out, FILE * which ):
        cdef char * temp = out 
        if self.opened:
            if isinstance( out, unicode ):
                out = out.encode( 'utf-8' )
            written = fwrite( temp, len(out), 1, which  )
            if written != 1:
                raise IOError( "Unable to write to output file" )
    
    cdef clean_name( self, str name ):
        return urllib.quote( name )
    
    def prefix( self ):
        return self.write_prefix()
    cdef write_prefix( self ):
        message = b'P COLDSHOTBinary v%s '%( self.version, )
        self.write_string( message, self.index_fd )
        self.write_long_long( 1, self.index_fd )
        self.write_string( '\n', self.index_fd )
    
    def file( self, int fileno, str filename ):
        return self.write_file( fileno, filename )
    cdef write_file( self, int fileno, str filename ):
        self.write_string( 'F %d %s\n'%( fileno, self.clean_name( filename )), self.index_fd)
    
    def func( self, fileno, lineno, name ):
        return self.write_func( fileno, lineno, name )
    cdef write_func( self, int fileno, int lineno, str name ):
        self.write_string( 
            'f %hi %hi %s\n'%( fileno, lineno, self.clean_name(name) ), 
            self.index_fd
        )
    
    def call( self, threadno, fileno, lineno, ts ):
        return self.write_call( threadno, fileno, lineno, ts )
    cdef write_call( self, long threadno, int fileno, int lineno, PY_LONG_LONG ts ):
        self.write_string( 'c', self.calls_fd )
        self.write_long( threadno, self.calls_fd )
        self.write_short( fileno, self.calls_fd )
        self.write_short( lineno, self.calls_fd )
        self.write_long_long( ts, self.calls_fd )
    
    def return_( self, threadno, fileno, lineno, ts ):
        return self.write_return( threadno, fileno, lineno, ts )
    cdef write_return( self, long threadno, int fileno, int lineno, PY_LONG_LONG ts ):
        self.write_string( 'r', self.calls_fd )
        self.write_long( threadno, self.calls_fd )
        self.write_short( fileno, self.calls_fd )
        self.write_short( lineno, self.calls_fd )
        self.write_long_long( ts, self.calls_fd )
    
    def line( self, threadno, lineno, ts ):
        return self.write_line( threadno, lineno, ts )
    cdef write_line( self, long threadno, int lineno, PY_LONG_LONG ts ):
        self.write_long( threadno, self.lines_fd )
        self.write_short( 0, self.lines_fd )
        self.write_short( lineno, self.lines_fd )
        self.write_long_long( ts, self.lines_fd )
    
    def flush( self ):
        fflush( self.index_fd )
        fflush( self.calls_fd )
        fflush( self.lines_fd )
    
    def close( self ):
        self._close()
    cdef _close( self ):
        if self.opened:
            self.opened = 0
            fclose( self.index_fd )
            fclose( self.calls_fd )
            fclose( self.lines_fd )
    def __dealloc__( self ):
        self._close()

cdef class Profiler:
    """Coldshot Profiler implementation 
    
    >>> import coldshot
    >>> p = coldshot.Profiler( 'test.profile' )
    >>> p.filename
    'test.profile'
    >>> p.index_filename
    'test.profile.index'
    """
    cdef dict files
    cdef int next_file
    cdef set functions
    cdef public Writer writer
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
    cdef thread_id( self, PyFrameObject frame ):
        return frame.f_tstate.thread_id
        
    cdef write_call( self, PY_LONG_LONG ts, PyFrameObject frame ):
        cdef PyCodeObject code
        code = frame.f_code[0]
        fileno = self.file_to_number( code )
        lineno = code.co_firstlineno
        key = (fileno,lineno)
        if key not in self.functions:
            self.functions.add( key )
            self.writer.write_func( fileno, lineno, <object>(code.co_name) )
        self.writer.write_call( self.thread_id( frame ), fileno, lineno, ts)
    cdef write_return( self, PY_LONG_LONG ts, PyFrameObject frame ):
        code = frame.f_code[0]
        fileno = self.file_to_number( code )
        lineno = code.co_firstlineno
        self.writer.write_return( self.thread_id( frame ), fileno, lineno, ts )
    cdef write_line( self, PY_LONG_LONG ts, PyFrameObject frame ):
        self.writer.write_line( self.thread_id( frame ), frame.f_lineno, ts )
    
    cdef delta( self ):
        """Calculate the delta since the last call to hpTimer(), store new value
        
        TODO: this discounting needs to be per-thread, but that isn't quite right 
        either, as there is very different behaviour if the other thread is GIL-free 
        versus GIL-locked (if it's locked, we should discount, otherwise we should 
        not).
        """
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

cdef int trace_callback(
    object self, 
    PyFrameObject *frame, 
    int what,
    object arg
):
    cdef Profiler profiler = <Profiler>self
    ts = profiler.delta()
    if what == PyTrace_LINE:
        profiler.write_line( ts, frame[0] )
    elif what == PyTrace_CALL:
        profiler.write_call( ts, frame[0] )
    elif what == PyTrace_RETURN:
        profiler.write_return( ts, frame[0] )
    profiler.discount()
    return 0
