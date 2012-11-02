"""Load/map/iterate over a data-file on disk"""
from coldshot cimport event_info, mmap_object
cdef class MappedFile:
    """Memory-mapped file used for scanning large data-files"""
    cdef object filename 
    cdef long filesize
    cdef object fh 
    cdef object mm
    cdef public long record_count
    
cdef class CallsFile(MappedFile):
    """Particular mapped file which loads our callsfile data-structures"""
    cdef event_info * records 
        
cdef class CallsIterator:
    """Provide python-level iteration over a CallsFile"""
    cdef CallsFile records
    cdef long position
