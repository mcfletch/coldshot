"""Coldshot, a Hotshot-like profiler implementation in Cython
"""
from cpython cimport PY_LONG_LONG
import urllib, os, weakref
from coldshot cimport *

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
    
    cdef write_callinfo( self, uint16_t thread, int16_t stack_depth, uint32_t function, uint32_t timestamp ):
        cdef call_info local 
        local.thread = thread 
        local.stack_depth = stack_depth
        local.function = function 
        local.timestamp = timestamp
        written = fwrite( &local, sizeof(call_info), 1, self.calls_fd )
        if written != 1:
            raise RuntimeError( """Unable to write to file: %s"""%( self.calls_filename, ))
    cdef write_lineinfo( self, uint16_t thread, uint16_t fileno, uint16_t lineno, uint32_t timestamp ):
        cdef line_info local 
        local.thread = thread 
        local.fileno = fileno 
        local.lineno = lineno 
        local.timestamp = timestamp
        written = fwrite( &local, sizeof(line_info), 1, self.lines_fd )
        if written != 1:
            raise RuntimeError( """Unable to write to file: %s"""%( self.lines_filename, ))

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
    cdef public PY_LONG_LONG internal_start
    cdef public PY_LONG_LONG internal_discount
    
    def __init__( self, dirname, version=1 ):
        self.writer = Writer( dirname, version )
        self.writer.prefix()
        self.files = {}
        self.functions = {}
        self.threads = {}
        
    cdef uint32_t file_to_number( self, PyCodeObject code ):
        """Convert a code reference to a file number"""
        cdef uint32_t count
        filename = <object>(code.co_filename)
        if filename not in self.files:
            count = len( self.files ) + 1
            self.files[filename] = (count, filename)
            self.writer.write_file( count, filename )
            return count
        return <uint32_t>(self.files[filename][0])
    cdef uint32_t func_to_number( self, PyCodeObject code ):
        """Convert a function reference to a persistent function ID"""
        cdef tuple key 
        cdef bytes name
        cdef uint32_t count
        cdef int fileno
        key = (<object>code.co_filename,<int>code.co_firstlineno)
        if key not in self.functions:
            fileno = self.file_to_number( code )
            name = b'%s.%s'%(<object>code.co_filename,<object>code.co_name)
            count = len(self.functions)+1
            self.functions[key] = (count, name)
            self.writer.write_func( count, fileno, code.co_firstlineno, name)
            return count
        return <uint32_t>(self.functions[key][0])
    cdef uint32_t builtin_to_number( self, PyCFunctionObject * func ):
        """Convert a builtin-function reference to a persistent function ID
        
        Note: assumes that builtin function IDs (pointers) are persistent 
        and unique.
        """
        cdef long id 
        cdef uint32_t count
        cdef bytes name
        id = <long>func # ssize_t?
        if id not in self.functions:
            name = builtin_name( func[0] )
            count = len(self.functions) + 1
            self.functions[id] = (count, name)
            self.writer.write_func( count, 0, 0, name )
            return count
        return <uint32_t>(self.functions[id][0])
    
    # Pass a formatted call onto the writer...
    cdef write_call( self, PyFrameObject frame ):
        cdef PyCodeObject code
        cdef int func_number 
        cdef uint32_t ts = self.timestamp()
        func_number = self.func_to_number( frame.f_code[0] )
        self.writer.write_callinfo( self.thread_id( frame ), self.stack_depth(frame), func_number, ts)
        
    cdef write_c_call( self, PyFrameObject frame, PyCFunctionObject * func ):
        cdef long id 
        cdef uint32_t ts = self.timestamp()
        cdef uint32_t func_number = self.builtin_to_number( func )
        self.writer.write_callinfo( self.thread_id( frame ), self.stack_depth(frame), func_number, ts)
        
    cdef write_return( self, PyFrameObject frame ):
        cdef uint32_t ts = self.timestamp()
        self.writer.write_callinfo( 
            self.thread_id( frame ), 
            # NOTE the - here!
            -self.stack_depth(frame),
            self.func_to_number( frame.f_code[0] ), 
            ts
        )
        
    cdef write_line( self, PyFrameObject frame ):
        cdef uint32_t ts = self.timestamp()
        self.writer.write_lineinfo( 
            self.thread_id( frame ), 
            self.file_to_number( frame.f_code[0] ), 
            frame.f_lineno, 
            ts 
        )
    
    # State introspection mechanisms
    cdef uint16_t thread_id( self, PyFrameObject frame ):
        """Extract thread_id and convert to a 16-bit integer..."""
        cdef long id 
        cdef int count
        id = <long>frame.f_tstate.thread_id
        if id not in self.threads:
            count = len(self.threads) + 1
            self.threads[id] = count 
            return <int>count
        return self.threads[id]
    cdef int16_t stack_depth( self, PyFrameObject frame ):
        """Count stack-depth for the given frame
        
        Note: limited to unsigned short int depth
        """
        cdef int16_t depth
        depth = 1
        while frame.f_back != NULL:
            depth += 1
            frame = frame.f_back[0]
        return depth
    cdef public uint32_t timestamp( self ):
        """Calculate the delta since the last call to hpTimer(), store new value
        
        TODO: this discounting needs to be per-thread, but that isn't quite right 
        either, as there is very different behaviour if the other thread is GIL-free 
        versus GIL-locked (if it's locked, we should discount, otherwise we should 
        not).
        """
        cdef PY_LONG_LONG delta
        current = hpTimer()
        return <uint32_t>( current - self.internal_start - self.internal_discount)
    cdef public PY_LONG_LONG discount( self, PY_LONG_LONG delta ):
        """Discount the time since the last call to hpTimer()"""
        self.internal_discount += delta 
        return self.internal_discount
    
    def start( self ):
        """Install this profiler as the trace function for the interpreter"""
        self.internal_discount = 0
        self.internal_start = hpTimer()
        PyEval_SetProfile(profile_callback, self)
        PyEval_SetTrace(trace_callback, self)
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
    if what == PyTrace_LINE:
        profiler.write_line( frame[0] )
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
    if what == PyTrace_CALL:
        profiler.write_call( frame[0] )
    elif what == PyTrace_C_CALL:
        if PyCFunction_Check( arg ):
            profiler.write_c_call( frame[0], <PyCFunctionObject *>arg )
    elif what == PyTrace_RETURN or what == PyTrace_C_RETURN:
        profiler.write_return( frame[0] )
    return 0
