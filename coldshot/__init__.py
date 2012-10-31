"""Coldshot is a deterministic Python profiler

Coldshot:

 * is a Python profiler which records all of the profile events to 
   disk (similar to the Hotshot profiler, hence the name)

 * focuses on allowing the creation of tools which can "deep dive" 
   into a trace
   
 * is coded primarily in Cython 
 
 * is compatible with Python 2.7
 
 * records "raw time" rather than discounting times based on a guess of the 
   impact of profiling

 * records thread IDs in each record to allow reconstructing per-thread traces
 
 * is still very early in its life-cycle.  The data-file format is not yet 
   finalized, as currently it is based on naturally-ordered (and packed) 
   structs, rather than a specific final format
"""
__version__ = '1.0.0a1'
from .profiler import *
from .loader import *
from .externals import *
