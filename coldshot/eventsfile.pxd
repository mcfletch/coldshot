"""Load/map/iterate over a data-file on disk"""
from coldshot cimport event_info, mmap_object

cdef class MappedFile:
    cdef object filename 
    cdef long filesize
    cdef object fh 
    cdef object mm
    cdef public long record_count
    
cdef class EventsFile(MappedFile):
    cdef event_info * records 

cdef class CallsIterator:
    cdef EventsFile records
    cdef long position
