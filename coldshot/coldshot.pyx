"""Coldshot, a Hotshot replacement in Cython"""
import urllib 

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


cdef extern from 'lowlevel.h':
    void coldshot_set_trace( void * callback, object arg )
    void coldshot_unset_trace()

cdef class Writer:
    cdef int version
    cdef object output
    def __cinit__( self, output ):
        self.output = output
        self.version = 1
    cdef clean_name( self, str name ):
        return urllib.quote( name )
    cdef write_prefix( self ):
        self.output( 'W %i\n'%( self.version, ) )
    cdef write_file( self, int fileno, str filename ):
        self.output( 'F %i %s\n'%( fileno, self.clean_name(filename) ))
    cdef write_func( self, int fileno, int lineno, str name ):
        self.output( 'f %i %i %s\n'%( fileno, lineno, self.clean_name(name) ))
    cdef write_call( self, int fileno, int lineno, float ts ):
        self.output( 'C %i %i %f\n'%( fileno, lineno, ts ) )
    cdef write_return( self, float ts ):
        self.output( 'R %f\n'%( ts, ))
    cdef write_line( self, int lineno, float ts ):
        self.output( 'L %i %f\n'%( lineno, ts ))

cdef class Profiler:
    cdef dict files
    cdef int next_file
    cdef set functions
    cdef Writer writer
    def __init__( self, file ):
        self.writer = Writer( file.write )
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
        ts = self.get_time()
        code = frame.f_code[0]
        fileno = self.file_to_number( code )
        lineno = code.co_firstlineno
        key = (fileno,lineno)
        if key not in self.functions:
            self.functions.add( key )
            self.writer.write_func( fileno, lineno, <object>(code.co_name) )
        self.writer.write_call( fileno, lineno, ts)
    cdef write_return( self, PyFrameObject frame ):
        ts = self.get_time()
        self.writer.write_return( ts )
    cdef write_line( self, PyFrameObject frame ):
        ts = self.get_time()
        self.writer.write_line( frame.f_lineno, ts )
    
    def start( self ):
        coldshot_set_trace( <void *>callback, self )
    def stop( self ):
        coldshot_unset_trace( )

cdef callback( Profiler instance, PyFrameObject frame, int what, object arg ):
    if what == PyTrace_LINE:
        instance.write_line( frame )
    elif what == PyTrace_C_CALL:
        instance.write_call( frame )
    elif what == PyTrace_C_RETURN:
        instance.write_return( frame )
