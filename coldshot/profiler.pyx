"""Coldshot, a Hotshot-like profiler implementation in Cython
"""
from cpython cimport PY_LONG_LONG
import urllib, os, weakref, sys
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
        void * f_globals
        int f_lineno

# timers, from line_profiler
cdef extern from "timers.h":
    PY_LONG_LONG hpTimer()
    double hpTimerUnit()

# pretty much the same code as line-profiler
cdef extern from 'lowlevel.h':
    void coldshot_unset_trace()
    void coldshot_unset_profile()

CALL_INFO_SIZE = sizeof( call_info )
TIMER_UNIT = hpTimerUnit()
    
__all__ = [
    'timer',
    'Profiler',
]

def timer():
    return <long>hpTimer()

cdef class DataWriter:
    cdef bint opened
    cdef bytes filename
    cdef FILE * fd 
    def __cinit__( self, filename not None ):
        if isinstance( filename, unicode ):
            filename = filename.encode( 'utf-8' )
        self.filename = filename 
        self.fd = self.open_file( self.filename )
        self.opened = True
    def flush( self ):
        """Flush our file descriptor's buffers"""
        if self.opened:
            fflush( self.fd )
    def close( self ):
        """Close (safe to call multiple times)"""
        self._close()
    cdef _close( self ):
        """C-level closing operation"""
        if self.opened:
            self.opened = False
            fflush( self.fd )
            fclose( self.fd )
    def __dealloc__( self ):
        self._close()
        self.filename = None
    
    cdef FILE * open_file( self, bytes filename ):
        cdef FILE * fd 
        fd = fopen( <char *>filename, 'w' )
        if fd == NULL:
            raise IOError( "Unable to open output file: %s", filename )
        return fd
    cdef ssize_t write_void( self, void * data, ssize_t size ):
        cdef ssize_t written
        if not self.opened:
            raise IOError( """Attempt to write to un-opened (or closed) file %s"""%( self.filename, ))
        written = fwrite( data, size, 1, self.fd )
        if written != 1:
            raise IOError( """Unable to write to file: %s"""%( self.filename, ))
        return written
    def write( self, thread, function, timestamp, line, flags ):
        """Write a record to the file (for testing)"""
        return self.write_callinfo( thread, function, timestamp, line, flags )
    cdef ssize_t write_callinfo( 
        self, 
        uint16_t thread, 
        uint32_t function, 
        uint32_t timestamp, 
        uint16_t line, 
        uint32_t flags,
    ):
        """Write our call_info record
        
            uint16_t thread 
            uint16_t line
            uint32_t function # high byte is flags...
            uint32_t timestamp # 1/10**6 seconds
        
        returns number of records written (should always be 1)
        """
        cdef call_info local 
        cdef ssize_t written
        cdef uint32_t flag_mask = 0xff000000
        local.thread = thread 
        
        flags = flags & flag_mask
        local.function = function | flags
        local.line = line 
        local.timestamp = timestamp
        written = self.write_void( &local, sizeof( call_info ))
        return written

cdef class IndexWriter(object):
    """Writes the (plain-text) index to a standard Python file
    
    Record types written:
    
        P COLDSHOTBinary v<version> byteswap=<boolean>
        
            Prefix record, declares version, byteswap=True means the file 
            was written on a big-endian machine (currently ignored, which 
            means profiles are not portable across architectures)
        
        D calls <filename>
        
            Declares a calls file to be loaded by the loader.
            
        D lines <filename>
        
            Declares a line-trace file to be loaded by the loader.
        
        F 23 <filename>
        
            Declares a file number for line traces and function identification
        
        f 34 <fileno> <lineno> <module> <functionname>
        
            Declares a function number, builtin functions will always have 
            fileno:lineno of 0:0
    
    Formatting:
    
        numbers are written in base 10 str() representations
        
        strings are written in urllib.quote()'d form
    """
    cdef object fh
    cdef bint should_close # note: means "we should close it", not "has been opened"
    def __init__( self, file ):
        """Open the IndexWriter
        
        file -- if a str/bytes object, then open that file, otherwise use 
            file as a writeable object 
        """
        if isinstance( file, (bytes,unicode)):
            self.fh = open( file, 'wb' )
            self.should_close = True
        else:
            self.fh = file 
            self.should_close = False
    def prefix( self, version=1 ):
        """Write our version prefix to the data-file"""
        message = b'P COLDSHOTBinary version=%d bigendian=%s timer_unit=%f\n'%( 
            version, sys.byteorder=='big', 
            TIMER_UNIT 
        )
        self.fh.write( message )
    def write_datafile( self, datafile, type='calls' ):
        """Record the presence of a data-file to be parsed"""
        datafile = urllib.quote( datafile )
        message = b'D %(type)s %(datafile)s\n'%locals()
        self.fh.write( message )
    def write_file( self, fileno, filename ):
        message = b'F %d %s\n'%( fileno, urllib.quote( filename ))
        self.fh.write( message )
    def write_func( self, funcno, fileno, lineno, bytes module, bytes name ):
        name = urllib.quote( name )
        module = urllib.quote( module )
        message = b'f %(funcno)d %(fileno)d %(lineno)d %(module)s %(name)s\n'%locals()
        self.fh.write( message )
    def flush( self ):
        self.fh.flush()
    def close( self ):
        if self.should_close:
            self.should_close = False
            self.fh.close()
    
cdef class Profiler:
    """Coldshot Profiler implementation 
    
    >>> import coldshot
    >>> p = coldshot.Profiler( 'test.profile' )
    >>> p.start()
    ...
    >>> p.stop()
    """
    cdef public dict files
    cdef public dict functions
    cdef public dict threads
    
    cdef public IndexWriter index
    cdef public DataWriter calls
    
    cdef public PY_LONG_LONG internal_start
    cdef public PY_LONG_LONG internal_discount
    
    cdef uint32_t RETURN_FLAGS 
    cdef uint32_t CALL_FLAGS 
    cdef uint32_t LINE_FLAGS
    
    cdef int active
    cdef int lines
    
    INDEX_FILENAME = b'index.coldshot'
    CALLS_FILENAME = b'coldshot.data'
    
    def __init__( self, dirname, lines=True, version=1 ):
        """Initialize the profiler (and open all files)
        
        dirname -- directory in which to record profiles 
        lines -- if True, write line traces (default is True)
        version -- file-format version to write
        """
        if not os.path.exists( dirname ):
            os.makedirs( dirname )
        index_filename = os.path.join( dirname, self.INDEX_FILENAME )
        self.index = IndexWriter( index_filename )
        calls_filename = os.path.join( dirname, self.CALLS_FILENAME )
        self.calls = DataWriter( calls_filename )
        
        self.index.prefix(version=version)
        self.index.write_datafile( calls_filename, 'calls' )
        
        self.lines = lines
        
        self.files = {}
        self.functions = {}
        self.threads = {}
        self.active = False
        
        self.LINE_FLAGS = 0 << 24 # just for consistency
        self.CALL_FLAGS = 1 << 24
        self.RETURN_FLAGS = 2 << 24
        
    cdef uint32_t file_to_number( self, PyCodeObject code ):
        """Convert a code reference to a file number"""
        cdef uint32_t count
        cdef object count_obj
        cdef bytes filename = <bytes>(code.co_filename)
        count_obj = self.files.get( filename )
        if count_obj is None:
            count = len( self.files ) + 1
            self.files[filename] = count
            self.index.write_file( count, os.path.abspath( filename ) )
        else:
            count = <long>count_obj
        return count
    cdef uint32_t func_to_number( self, PyFrameObject frame ):
        """Convert a function reference to a persistent function ID"""
        cdef PyCodeObject code = frame.f_code[0]
        cdef tuple key 
        cdef bytes name
        cdef bytes module 
        cdef uint32_t count
        cdef object count_obj
        cdef int fileno
        key = (<object>code.co_filename,<int>code.co_firstlineno)
        count_obj = self.functions.get( key )
        if count_obj is None:
            fileno = self.file_to_number( code )
            try:
                module = (<object>frame.f_globals)['__name__']
            except KeyError as err:
                module = <bytes>code.co_filename
            name = <bytes>(code.co_name)
            count = <uint32_t>(len(self.functions)+1)
            self.functions[key] = count
            self.index.write_func( count, fileno, code.co_firstlineno, module, name)
        else:
            count = <long>count_obj
        return <uint32_t>count
    cdef uint32_t builtin_to_number( self, PyCFunctionObject * func ):
        """Convert a builtin-function reference to a persistent function ID
        
        Note: assumes that builtin function IDs (pointers) are persistent 
        and unique.
        """
        cdef ssize_t id 
        cdef uint32_t count
        cdef object count_obj
        cdef bytes name
        cdef bytes module 
        id = <ssize_t>(func.m_ml) # ssize_t?
        count_obj = self.functions.get( id )
        if count_obj is None:
            name = builtin_name( func[0] )
            module = module_name( func[0] )
            count = len(self.functions) + 1
            self.functions[id] = count
            self.index.write_func( count, 0, 0, module, name )
        else:
            count = <long>count_obj
        return count
    cdef uint16_t thread_id( self, PyFrameObject frame ):
        """Extract thread_id and convert to a 16-bit integer..."""
        cdef long id 
        cdef uint16_t count
        cdef object count_obj
        id = <long>frame.f_tstate.thread_id
        count_obj = self.threads.get( id )
        if count_obj is None:
            count = len(self.threads) + 1
            self.threads[id] = count 
        else:
            count = <long>count_obj
        return count
    
    # Pass a formatted call onto the writer...
    cdef write_call( self, PyFrameObject frame ):
        cdef PyCodeObject code
        cdef int func_number 
        cdef uint32_t ts = self.timestamp()
        func_number = self.func_to_number( frame )
        self.calls.write_callinfo( 
            self.thread_id( frame ), 
            func_number, 
            ts, 
            frame.f_lineno,
            self.CALL_FLAGS,
        )
        
    cdef write_c_call( self, PyFrameObject frame, PyCFunctionObject * func ):
        cdef uint32_t ts = self.timestamp()
        cdef uint32_t func_number = self.builtin_to_number( func )
        self.calls.write_callinfo( 
            self.thread_id( frame ), 
            func_number, 
            ts, 
            frame.f_lineno,
            self.CALL_FLAGS,
        )
        
    cdef write_return( self, PyFrameObject frame ):
        cdef uint32_t ts = self.timestamp()
        self.calls.write_callinfo( 
            self.thread_id( frame ), 
            self.func_to_number( frame ), 
            ts,
            frame.f_lineno,
            self.RETURN_FLAGS,
        )
        
    cdef write_line( self, PyFrameObject frame ):
        cdef uint32_t ts = self.timestamp()
        cdef uint16_t thread = self.thread_id( frame )
        cdef uint32_t function =  self.func_to_number( frame )
        self.calls.write_callinfo( 
            thread, 
            function, 
            ts,
            frame.f_lineno & 0xffff, 
            self.LINE_FLAGS,
        )
    
    # State introspection mechanisms
    cdef public uint32_t timestamp( self ):
        """Calculate the delta since the last call to hpTimer(), store new value
        
        TODO: this discounting needs to be per-thread, but that isn't quite right 
        either, as there is very different behaviour if the other thread is GIL-free 
        versus GIL-locked (if it's locked, we should discount, otherwise we should 
        not).
        """
        cdef PY_LONG_LONG delta
        cdef PY_LONG_LONG current = hpTimer()
        delta = current - self.internal_start - self.internal_discount
        #delta = delta & 0xffffffff
        return <uint32_t>delta
    
#    def __enter__( self ):
#        """Start the profiler on entry"""
#        self.start()
#    def __exit__( self, type, value, traceback ):
#        """Stop the profiler on exit"""
#        self.stop()
    
    # External api
    def start( self ):
        """Install this profiler as the trace function for the interpreter"""
        if self.active:
            return 
        self.active = True
        self.internal_discount = 0
        self.internal_start = hpTimer()
        PyEval_SetProfile(profile_callback, self)
        if self.lines:
            PyEval_SetTrace(trace_callback, self)
    def stop( self ):
        """Remove the currently installed profiler (even if it is not us)"""
        if not self.active:
            return 
        self.active = False
        coldshot_unset_profile()
        if self.lines:
            coldshot_unset_trace()
        self.index.flush()
        self.calls.flush()

cdef bytes module_name( PyCFunctionObject func ):
    cdef object local_mod
    if func.m_self != NULL:
        # is a method, use the type's name as the key...
        local_mod = (<object>func.m_self).__class__
        return b'%s.%s'%(local_mod.__module__,local_mod.__name__)
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
    func_name = func.m_ml[0].ml_name
    return func_name

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
    cdef Profiler profiler = <Profiler>self
    if what == PyTrace_CALL:
        profiler.write_call( frame[0] )
    elif what == PyTrace_C_CALL:
        if PyCFunction_Check( arg ):
            profiler.write_c_call( frame[0], <PyCFunctionObject *>arg )
    elif what == PyTrace_RETURN or what == PyTrace_C_RETURN:
        profiler.write_return( frame[0] )
    return 0
