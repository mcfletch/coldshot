"""Coldshot Profiler implementation
"""
from cpython cimport PY_LONG_LONG
import os, weakref, sys, logging
try:
    from urllib import parse as urllib
except ImportError as error:
    import urllib
from coldshot cimport *
log = logging.getLogger( __name__ )

CALL_INFO_SIZE = sizeof( event_info )
TIMER_UNIT = hpTimerUnit()
    
__all__ = [
    'timer',
    'Profiler',
    'Extractor',
    'ThreadExtractor',
    'DataWriter',
    'IndexWriter',
]

def timer():
    """Return the current high-resolution timer value"""
    return <long>hpTimer()

cdef class DataWriter(object):
    """Object to write data to a raw FILE pointer"""
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
        """Open the given filename for writing"""
        cdef FILE * fd 
        fd = fopen( <char *>filename, 'w' )
        if fd == NULL:
            raise IOError( "Unable to open output file: %s", filename )
        return fd
    cdef ssize_t write_void( self, void * data, ssize_t size ):
        """Write size bytes from data into our file"""
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
        """Write our event_info record
        
            uint16_t thread 
            uint16_t line
            uint32_t function # high byte is flags...
            uint32_t timestamp # 1/10**6 seconds
        
        returns number of records written (should always be 1)
        """
        cdef event_info local 
        cdef ssize_t written
        cdef uint32_t flag_mask = 0xff000000
        local.thread = thread 
        
        flags = flags & flag_mask
        local.function = function | flags
        local.line = line 
        local.timestamp = timestamp
        written = self.write_void( &local, sizeof( event_info ))
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
        message = 'P COLDSHOTBinary version=%d bigendian=%s timer_unit=%f\n'%( 
            version, sys.byteorder=='big', 
            TIMER_UNIT 
        )
        self.fh.write( message.encode('utf-8') )
    def write_datafile( self, datafile, type='calls' ):
        """Record the presence of a data-file to be parsed"""
        datafile = urllib.quote( datafile )
        message = 'D %(type)s %(datafile)s\n'%locals()
        self.fh.write( message.encode('utf-8') )
    def write_file( self, fileno, filename ):
        """Record presence of a source file and its identifier"""
        message = 'F %d %s\n'%( fileno, urllib.quote( filename ))
        self.fh.write( message.encode('utf-8') )
    def write_func( self, funcno, fileno, lineno, bytes module, bytes name ):
        """Record presence of function and function id into the index"""
        name = urllib.quote( name )
        module = urllib.quote( module )
        message = 'f %(funcno)d %(fileno)d %(lineno)d %(module)s %(name)s\n'%locals()
        self.fh.write( message.encode('utf-8') )
    def write_annotation( self, funcno, description ):
        if isinstance( description, unicode ):
            description = description.encode( 'utf-8' )
        if not isinstance( description, str ):
            description = str( description )
        description = urllib.quote( description )
        message = 'A %(funcno)d %(description)s\n'%locals()
        self.fh.write( message.encode('utf-8') )
    def flush( self ):
        """Flush our buffer"""
        self.fh.flush()
    def close( self ):
        """Close our file"""
        if self.should_close:
            self.should_close = False
            self.fh.close()

cdef class Extractor( object ):
    """Extractors are objects which are used to extract data-points at run-time"""
    def __cinit__( self ):
        self.members = {}
    cdef long new_id( self, object key ):
        """Calculate new id for the given key"""
        cdef object count
        count = self.members.get( key )
        if count is None:
            count = len(self.members) + 1
            self.members[key] = count
        return count

cdef class ThreadExtractor( Extractor ):
    """Replacable object providing extraction of values to record
    
    ThreadExtractor is an abstraction point that allows for using non-thread 
    IDs in the "thread" member of profiles.  In a non-threaded environment, this 
    would allow for e.g. setting "green thread ID" or "uthread id".
    """
    cdef uint16_t extract( self, PyFrameObject frame, Profiler profiler ):
        """Extract and return a 16-bit integer for the "thread" value
        
        This is the publicly accessible API called to retrieve the value 
        for a "Thread ID"
        """
        return self.new_id( <long>(frame.f_tstate.thread_id) )

cdef class Profiler(object):
    """Coldshot Profiler implementation 
    
    Profilers act as context managers for use with the ``with`` statement::
    
        with Profiler( 'test.profile', lines=True ):
            do_something()
    """
    INDEX_FILENAME = b'index.coldshot'
    CALLS_FILENAME = b'coldshot.data'
    
    def __init__( self, dirname, lines=True, version=1, thread_extractor=None ):
        """Initialize the profiler (and open all files)
        
        dirname -- directory in which to record profiles 
        
        lines -- if True, write line traces (default is True)
        
        thread_extractor -- if provided, thread extractor for all events 
        
            This object must be an instance of ThreadExtractor, and should 
            (read must) be implemented in C/Cython to provide acceptable 
            performance.
            
            The primary purpose of passing in this object is to allow for 
            creating e.g. micro-thread or similar thread IDs instead of pthread 
            IDs.
            
            ``thread_extractor.extract( PyFrameObject ) -> uint16_t id ``
            ``thread_extractor.new_id( thread_id ) -> uint16_t id``
        
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
        if thread_extractor is not None:
            self.threads = thread_extractor
        else:
            self.threads = ThreadExtractor()
        self.active = False
        self.internal = False
        self.internal_start = 0
        
        self.LINE_FLAGS = 0 << 24 # just for consistency
        self.CALL_FLAGS = 1 << 24
        self.RETURN_FLAGS = 2 << 24
        self.ANNOTATION_FLAGS = 3 << 24
        
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
    cdef uint32_t annotation_to_number( self, object key ):
        cdef object count_obj = self.functions.get( key )
        cdef uint32_t none_value = 0
        if key is None:
            return none_value
        count_obj = self.functions.get( key )
        if count_obj is None:
            count = <uint32_t>(len(self.functions)+1)
            self.functions[key] = count
            self.index.write_annotation( count, key )
        return count
    
    cdef uint16_t thread_id( self, PyFrameObject frame ):
        """Just an indirection point for temporary testing"""
        return self.threads.extract( frame, self )
        
    cdef uint32_t func_to_number( self, PyFrameObject frame ):
        """Convert a function reference to a persistent function ID"""
        cdef PyCodeObject code = frame.f_code[0]
        cdef ssize_t key 
        cdef bytes name
        cdef bytes module 
        cdef uint32_t count
        cdef object count_obj
        cdef int fileno
        # Key is the "id" of the code...
        key = <ssize_t>frame.f_code
        count_obj = self.functions.get( key )
        if count_obj is None:
            fileno = self.file_to_number( code )
            try:
                module = (<object>frame.f_globals)['__name__']
            except KeyError as err:
                module = <bytes>code.co_filename
                log.warn( 'No __name__ in %s', module )
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
    
    # Pass a formatted call onto the writer...
    cdef write_call( self, PyFrameObject frame ):
        """Write a call record for the given frame into our calls-file"""
        cdef PyCodeObject code
        cdef int func_number 
        cdef uint32_t ts
        if self.internal:
            return
        ts = self.timestamp()
        func_number = self.func_to_number( frame )
        self.calls.write_callinfo( 
            self.thread_id( frame ), 
            func_number, 
            ts, 
            frame.f_lineno,
            self.CALL_FLAGS,
        )
        
    cdef write_c_call( self, PyFrameObject frame, PyCFunctionObject * func ):
        """Write a call to a C function for the frame and object into our calls-file"""
        cdef uint32_t ts
        cdef uint32_t func_number
        if self.internal:
            return
        ts = self.timestamp()
        func_number = self.builtin_to_number( func )
        self.calls.write_callinfo( 
            self.thread_id( frame ), 
            func_number, 
            ts, 
            frame.f_lineno,
            self.CALL_FLAGS,
        )
        
    cdef write_return( self, PyFrameObject frame ):
        """Write a return-from-call for the frame into the calls-file"""
        cdef uint32_t ts = self.timestamp()
        if self.internal:
            return
        self.calls.write_callinfo( 
            self.thread_id( frame ), 
            self.func_to_number( frame ), 
            ts,
            frame.f_lineno,
            self.RETURN_FLAGS,
        )
        
    cdef write_line( self, PyFrameObject frame ):
        """Write a line-event into the calls-file"""
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
        cdef uint32_t mask
        cdef PY_LONG_LONG current = hpTimer()
        delta = current - self.internal_start - self.internal_discount
        #delta = delta & mask
        return <uint32_t>delta
    
    def __enter__( self ):
        """Start the Profiler on entry (with statement starts)"""
        self.start()
    def __exit__( self, type, value, traceback ):
        """Stop the Profiler on exit (with statement stops)"""
        self.stop()
    
    # External api
    def start( self ):
        """Install this profiler as the profile/trace function for the interpreter
        
        On calling start, the profiler will register a callback function such that 
        we get callbacks which will emit events into the data-files.
        """
        if self.active:
            return 
        self.active = True
        self.internal_discount = 0
        # TODO: wrong, this will cause time to go backward!
        if self.internal_start == 0:
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
        self.flush()
    
    def flush( self ):
        """Flush our results to disk
        
        This operation is not generally intended to be used by client code.
        It allows code to ensure that all currently written events are flushed 
        to the data-files.  :py:meth:`stop` will automatically flush the 
        profiler results.
        """
        self.index.flush()
        self.calls.flush()
    
    def close( self ):
        """Close our files
        
        After closing all attempts to use the profiler will cause errors,
        as attempts to write data will all fail.
        """
        if self.active:
            self.stop()
        self.index.close()
        self.calls.close()
    
    # possible API
    def annotation( self, annotation, uint16_t lineno=0 ):
        """Set annotation id (edge-triggered)
        
        annotation -- a hashable object to insert into the index
        
            assign a "function id" (24-bit integer space shared among 
            functions and annotations).  Should *not* be an integer or a 
            value which == an integer (float or the like).  All values 
            are converted to 8-bit strings, so if you need a structured 
            store, use e.g. json encoding and pass the 8-bit string for 
            reconstruction

            None -- special indicator, will insert a function id of 0,
            which will be treated as an annotation-stack "pop" by readers.
        
        lineno -- a 16-bit integer passed into the final record
        
            whatever arbitrary 16-bit value you would like to store
        """
        cdef uint32_t ts
        cdef uint16_t thread
        self.internal = True
        thread = self.threads.new_id(PyThreadState_Get().thread_id)
        ts = self.timestamp()
        self.calls.write_callinfo(
            thread,
            self.annotation_to_number( annotation ),
            ts,
            lineno,
            self.ANNOTATION_FLAGS,
        )
        self.internal = False

cdef bytes module_name( PyCFunctionObject func ):
    """Extract the module name from the function reference"""
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
    """Extract the name from a C function object"""
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
#    elif what == PyTrace_EXCEPTION or what == PyTrace_C_EXCEPTION:
#        pass #profiler.write_exception( 
    elif what == PyTrace_RETURN or what == PyTrace_C_RETURN:
        profiler.write_return( frame[0] )
    return 0
