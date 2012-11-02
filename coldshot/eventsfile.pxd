"""Load/map/iterate over a data-file on disk"""
from coldshot cimport event_info, mmap_object, uint16_t, uint32_t

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

cdef uint16_t swap_16( uint16_t input )
cdef uint32_t swap_32( uint32_t input )
