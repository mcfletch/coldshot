from coldshot cimport *
from cpython cimport PY_LONG_LONG

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
    int PyTrace_EXCEPTION
    int PyTrace_C_EXCEPTION
    
    ctypedef struct PyCodeObject:
        void * co_filename
        void * co_name
        int co_firstlineno
    
    ctypedef struct PyThreadState:
        long thread_id
    
    cdef void PyEval_SetProfile(Py_tracefunc func, object arg)
    cdef void PyEval_SetTrace(Py_tracefunc func, object arg)
    cdef char * PyString_AsString(bytes string)
    cdef PyThreadState * PyThreadState_Get()

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

cdef class Profiler(object):
    cdef public dict files
    cdef public dict functions
    
    cdef public IndexWriter index
    cdef public DataWriter calls
    cdef public ThreadExtractor threads
    
    cdef public PY_LONG_LONG internal_start
    cdef public PY_LONG_LONG internal_discount
    
    cdef uint32_t RETURN_FLAGS 
    cdef uint32_t CALL_FLAGS 
    cdef uint32_t LINE_FLAGS
    cdef uint32_t ANNOTATION_FLAGS
    
    cdef bint active
    cdef bint lines
    cdef bint internal
    
    cdef uint32_t file_to_number( self, PyCodeObject code )
    cdef uint32_t annotation_to_number( self, object key )
    cdef uint16_t thread_id( self, PyFrameObject frame )
    cdef uint32_t func_to_number( self, PyFrameObject frame )
    cdef uint32_t builtin_to_number( self, PyCFunctionObject * func )
    cdef write_call( self, PyFrameObject frame )
    cdef write_c_call( self, PyFrameObject frame, PyCFunctionObject * func )
    cdef write_return( self, PyFrameObject frame )
    cdef write_line( self, PyFrameObject frame )
    cdef public uint32_t timestamp( self )


cdef class ThreadExtractor( object ):
    cdef dict members 
    cdef uint16_t new_id( self, object key )
    cdef uint16_t extract( self, PyFrameObject frame, Profiler profiler )

cdef class DataWriter(object):
    cdef bint opened
    cdef bytes filename
    cdef FILE * fd 
    cdef _close( self )
    cdef FILE * open_file( self, bytes filename )
    cdef ssize_t write_void( self, void * data, ssize_t size )
    cdef ssize_t write_callinfo( 
        self, 
        uint16_t thread, 
        uint32_t function, 
        uint32_t timestamp, 
        uint16_t line, 
        uint32_t flags,
    )
cdef class IndexWriter(object):
    cdef object fh
    cdef bint should_close # note: means "we should close it", not "has been opened"

