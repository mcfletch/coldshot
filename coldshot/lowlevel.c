/* Hack to hide Python API versions from the Cython code */
#include "Python.h"

void coldshot_unset_trace() {
    PyEval_SetTrace(NULL, NULL);
}
void coldshot_unset_profile() {
    PyEval_SetProfile(NULL, NULL);
}
