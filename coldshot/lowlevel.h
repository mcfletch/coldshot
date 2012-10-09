/* Hack to hide Python API versions from the Cython code */
#include "Python.h"

void coldshot_unset_trace();
void coldshot_unset_profile();
