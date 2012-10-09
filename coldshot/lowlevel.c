/* Hack to hide Python API versions from the Cython code */
#include "Python.h"

void coldshot_set_trace( void * callback, PyObject * arg ) {
    PyEval_SetTrace( (Py_tracefunc)callback, arg );
}

void coldshot_unset_trace() {
    PyEval_SetTrace(NULL, NULL);
}

void * format_long_long(PY_LONG_LONG * to_encode) {
    return to_encode;
}
