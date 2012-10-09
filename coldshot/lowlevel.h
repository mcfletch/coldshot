/* Hack to hide Python API versions from the Cython code */
#include "Python.h"

void coldshot_set_trace( void * callback, PyObject * arg );
void coldshot_unset_trace();
