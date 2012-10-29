"""Coldshot is a deterministic Python profiler

Coldshot is a Python profiler which records all of the profile events to 
disk (similar to the Hotshot profiler, hence the name).  Its focus is on 
allowing the creation of tools which can "deep dive" into a trace.

Coldshot is coded primarily in Cython.  The data-file format is not yet 
finalized, as currently it is based on naturally-ordered (and packed) 
structs, rather than a specific final format.

Coldshot is compatible with Python 2.7
"""
__version__ = '1.0.0a1'
from .profiler import *
from .loader import *
from .externals import *
