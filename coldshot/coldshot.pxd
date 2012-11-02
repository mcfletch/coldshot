"""Common declarations for Coldshot profiler and loader"""
cdef extern from "stdint.h":
    ctypedef int int8_t 
    ctypedef int uint8_t
    ctypedef int int16_t
    ctypedef int uint16_t
    ctypedef int int32_t
    ctypedef int uint32_t
    ctypedef int int64_t
    ctypedef int uint64_t

cdef extern from "minimalmmap.h":
    ctypedef struct mmap_object:
        void * data

# NOTE: These structures *must* use natural alignment, or everything will 
# go all to heck in a hand-basket!
cdef struct event_info:
    uint16_t thread
    uint16_t line
    uint32_t function # high byte is flags...
    uint32_t timestamp

