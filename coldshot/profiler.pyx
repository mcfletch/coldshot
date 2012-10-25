"""Coldshot, a Hotshot-like profiler implementation in Cython
"""
from cpython cimport PY_LONG_LONG
import urllib, os, weakref

cdef extern from "stdint.h":
    ctypedef int int32_t
    ctypedef int int16_t
    ctypedef int int64_t

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
    cdef char * PyString_AsString(bytes string)

cdef extern from 'pystate.h':
    object PyThreadState_GetDict()
    
cdef extern from 'methodobject.h':
    ctypedef struct PyMethodDef:
        char  *ml_name
    ctypedef struct PyCFunctionObject:
        PyMethodDef * m_ml
        void * m_self
        void * m_module
    cdef int PyCFunction_Check(object op)
    
cdef extern from 'frameobject.h':
    ctypedef struct PyFrameObject:
        PyCodeObject *f_code
        PyThreadState *f_tstate
        PyFrameObject *f_back
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
    ('rectype','S1'),('thread','i4'),('function','<i4'),('timestamp','<L'),('stack_depth', '<i2'),
]
LINES_STRUCTURE = [
    ('thread','i4'),('fileno','<i2'),('lineno','<i2'),('timestamp','<L')
]

def timer():
    return <long>hpTimer()

cdef class Writer:
    """Implements direct-to-file writing for the Profiler class
    
    Files created:
    
        index -- directory/index.profile
        lines -- directory/lines.data
        calls -- directory/calls.data
    """
    cdef int version
    
    cdef public bytes directory
    cdef public bytes index_filename 
    cdef public bytes lines_filename
    cdef public bytes calls_filename
    
    cdef int opened
    
    cdef size_t long_long_size
    
    cdef FILE * index_fd
    cdef FILE * lines_fd 
    cdef FILE * calls_fd 
    
    def __cinit__( self, directory, version=1 ):
        self.version = version
        
        if isinstance( directory, unicode ):
            directory = directory.encode( 'utf-8' )
        self.prepare_directory( directory )
        
        self.long_long_size = sizeof( PY_LONG_LONG )
    
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
        
        self.opened = <int>1
    
    cdef FILE * open_file( self, bytes filename ):
        cdef FILE * fd 
        fd = fopen( filename, 'w' )
        if fd == NULL:
            raise IOError( "Unable to open output file: %s", filename )
        return fd
    cdef write_short( self, short int out, FILE * which ):
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
    cdef write_string( self, bytes out, FILE * which ):
        cdef char * temp
        if self.opened:
            temp = PyString_AsString( out )
            written = fwrite( temp, len(out), 1, which  )
            if written != 1:
                raise IOError( "Unable to write to output file" )
    
    cdef clean_name( self, bytes name ):
        return urllib.quote( name )
    
    def prefix( self ):
        return self.write_prefix()
    cdef write_prefix( self ):
        message = b'P COLDSHOTBinary v%s '%( self.version, )
        self.write_string( message, self.index_fd )
        self.write_long_long( 1, self.index_fd )
        self.write_string( b'\n', self.index_fd )
    
    def file( self, int fileno, bytes filename ):
        return self.write_file( fileno, filename )
    cdef write_file( self, int fileno, bytes filename ):
        self.write_string( b'F %d %s\n'%( fileno, self.clean_name( filename )), self.index_fd)
    
    def func( self, count, fileno, lineno, name ):
        return self.write_func( count, fileno, lineno, name )
    cdef write_func( self, int count, int fileno, int lineno, bytes name ):
        self.write_string( 
            b'f %hi %hi %hi %s\n'%( count, fileno, lineno, self.clean_name(name) ), 
            self.index_fd
        )
    
    def call( self, threadno, funcno, ts, stack_depth ):
        return self.write_call( threadno, funcno, ts, stack_depth )
    cdef write_call( self, long threadno, int funcno, PY_LONG_LONG ts, int stack_depth ):
        self.write_string( b'c', self.calls_fd )
        self.write_long( threadno, self.calls_fd )
        self.write_long( funcno, self.calls_fd )
        self.write_long_long( ts, self.calls_fd )
        self.write_short( stack_depth, self.calls_fd )
    
    def return_( self, threadno, fileno, lineno, ts, stack_depth ):
        return self.write_return( threadno, fileno, lineno, ts, stack_depth )
    cdef write_return( self, long threadno, int fileno, int lineno, PY_LONG_LONG ts, int stack_depth ):
        self.write_string( b'r', self.calls_fd )
        self.write_long( threadno, self.calls_fd )
        self.write_short( fileno, self.calls_fd )
        self.write_short( lineno, self.calls_fd )
        self.write_long_long( ts, self.calls_fd )
        self.write_short( stack_depth, self.calls_fd )
    
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
    cdef public dict files
    cdef public dict functions
    cdef public dict threads
    
    cdef public Writer writer
    cdef public PY_LONG_LONG internal_time
    cdef public PY_LONG_LONG last_time
    def __init__( self, dirname, version=1 ):
        self.writer = Writer( dirname, version )
        self.writer.prefix()
        self.files = {}
        self.functions = {}
        self.threads = {}
        
    cdef int file_to_number( self, PyCodeObject code ):
        """Convert a code reference to a file number"""
        cdef int count
        filename = <object>(code.co_filename)
        if filename not in self.files:
            count = len( self.files ) + 1
            self.files[filename] = (count, filename)
            self.writer.write_file( count, filename )
            return count
        return <int>(self.files[filename][0])
    cdef int func_to_number( self, PyCodeObject code ):
        """Convert a function reference to a persistent function ID"""
        cdef tuple key 
        cdef bytes name
        cdef int count
        cdef int fileno
        key = (<object>code.co_filename,<int>code.co_firstlineno)
        if key not in self.functions:
            fileno = self.file_to_number( code )
            name = b'%s.%s'%(<object>code.co_filename,<object>code.co_name)
            count = len(self.functions)+1
            self.functions[key] = (count, name)
            self.writer.write_func( count, fileno, code.co_firstlineno, name)
            return count
        return <int>(self.functions[key][0])
    cdef int builtin_to_number( self, PyCFunctionObject * func ):
        """Convert a builtin-function reference to a persistent function ID
        
        Note: assumes that builtin function IDs (pointers) are persistent 
        and unique.
        """
        cdef long id 
        cdef int count
        cdef bytes name
        id = <long>func 
        if id not in self.functions:
            name = builtin_name( func[0] )
            count = len(self.functions) + 1
            self.functions[id] = (count, name)
            self.writer.write_func( count, 0, 0, name )
            return count
        return <int>(self.functions[id][0])
    cdef int thread_id( self, PyFrameObject frame ):
        """Convert a thread ID into a persistent thread identifier"""
        cdef long id 
        cdef int count
        id = <long>frame.f_tstate.thread_id
        if id not in self.threads:
            count = len(self.threads) + 1
            self.threads[id] = count 
            return <int>count
        return self.threads[id]
        
    cdef write_call( self, PY_LONG_LONG ts, PyFrameObject frame, int stack_depth ):
        cdef PyCodeObject code
        cdef int func_number 
        func_number = self.func_to_number( frame.f_code[0] )
        self.writer.write_call( self.thread_id( frame ), func_number, ts, stack_depth)
    cdef write_c_call( self, PY_LONG_LONG ts, PyFrameObject frame, PyCFunctionObject * func, int stack_depth ):
        cdef long id 
        cdef int func_number
        func_number = self.builtin_to_number( func )
        self.writer.write_call( self.thread_id( frame ), func_number, ts, stack_depth)

    cdef write_return( self, PY_LONG_LONG ts, PyFrameObject frame, int stack_depth ):
        code = frame.f_code[0]
        fileno = self.file_to_number( code )
        lineno = code.co_firstlineno
        self.writer.write_return( self.thread_id( frame ), fileno, lineno, ts, stack_depth )
    cdef write_line( self, PY_LONG_LONG ts, PyFrameObject frame ):
        self.writer.write_line( self.thread_id( frame ), frame.f_lineno, ts )
    
    cdef public PY_LONG_LONG delta( self ):
        """Calculate the delta since the last call to hpTimer(), store new value
        
        TODO: this discounting needs to be per-thread, but that isn't quite right 
        either, as there is very different behaviour if the other thread is GIL-free 
        versus GIL-locked (if it's locked, we should discount, otherwise we should 
        not).
        """
        cdef PY_LONG_LONG current
        cdef PY_LONG_LONG delta
        current = hpTimer()
        if current > self.last_time:
            delta = current - self.last_time
            self.internal_time += delta 
            self.last_time = current
        else:
            # cases where clock has gone backward e.g. multiprocessor weirdness
            delta = 0
        return self.internal_time
    cdef public PY_LONG_LONG discount( self ):
        """Discount the time since the last call to hpTimer()"""
        self.last_time = hpTimer()
        return self.internal_time
    
    def start( self ):
        """Install this profiler as the trace function for the interpreter"""
        PyEval_SetProfile(profile_callback, self)
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

cdef bytes module_name( PyCFunctionObject func ):
    cdef object local_mod
    if func.m_self != NULL:
        # is a method, use the type's name as the key...
        local_mod = (<object>func.m_self).__class__
        return b'%s.%s'%(local_mod.__module__,local_mod.__class__.__name__)
    else:
        if func.m_module != NULL:
            local_mod = <object>func.m_module
            if isinstance( local_mod, bytes ):
                return local_mod
            elif isinstance( local_mod, unicode ):
                return local_mod.encode( 'utf8' )
            else:
                return local_mod.__name__
        else:
            # func.m_module == NULL
            return b'__builtin__'
cdef bytes builtin_name( PyCFunctionObject func ):
    cdef object mod_name 
    cdef object func_name 
    mod_name = module_name( func )
    func_name = func.m_ml[0].ml_name
    return b'<%s.%s>'%(mod_name,func_name)

cdef short unsigned int _stack_depth( PyFrameObject * frame ):
    """Count stack-depth for the given frame
    
    Note: limited to unsigned short int depth
    """
    cdef short unsigned int depth
    depth = 1
    while frame[0].f_back != NULL:
        depth += 1
        frame = frame[0].f_back
    return depth

cdef int trace_callback(
    object self,
    PyFrameObject *frame,
    int what,
    object arg
):
    """Callback for trace (line) operations
    
    As of Python 2.7 the trace function does *not* seem to get c_call/c_return 
    events, which seems wrong/silly
    """
    cdef Profiler profiler = <Profiler>self
    ts = profiler.delta()
    if what == PyTrace_LINE:
        profiler.write_line( ts, frame[0] )
    profiler.discount()
    return 0
    
cdef int profile_callback(
    object self, 
    PyFrameObject *frame, 
    int what,
    object arg
):
    """Callback for profile (call/return, include C call/return) operations"""
    cdef int stack_depth
    cdef Profiler profiler = <Profiler>self
    
    ts = profiler.delta()
    stack_depth = _stack_depth( frame )
    
    if what == PyTrace_CALL:
        profiler.write_call( ts, frame[0], stack_depth )
    elif what == PyTrace_C_CALL:
        if PyCFunction_Check( arg ):
            profiler.write_c_call( ts, frame[0], <PyCFunctionObject *>arg, stack_depth )
    elif what == PyTrace_RETURN or what == PyTrace_C_RETURN:
        profiler.write_return( ts, frame[0], stack_depth )
    # discount the time during the profiler callback,
    # though this means multi-threaded operations may go backward in time...
    profiler.discount()
    return 0
