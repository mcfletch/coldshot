"""Load/map/iterate over a data-file on disk"""
import os, mmap, logging
from coldshot cimport event_info, mmap_object, uint16_t, uint32_t
log = logging.getLogger( __name__ )

cdef class MappedFile:
    """Memory-mapped file used for scanning large data-files"""
    def __cinit__( self, filename ):
        self.filename = filename
        self.fh = open( filename, 'rb' )
        self.filesize = os.stat( filename ).st_size 
        self.mm = mmap.mmap( self.fh.fileno(), self.filesize, prot=mmap.PROT_READ )
        self.get_pointer( self.mm )
    def close( self ):
        self.mm.close()
        self.fh.close()
    
cdef class EventsFile(MappedFile):
    """Particular mapped file which loads our eventsfile data-structures"""
    def get_pointer( self, mm ):
        cdef mmap_object * c_level
        c_level = <mmap_object *>mm
        self.records = <event_info *>(c_level[0].data)
        self.record_count = self.filesize // sizeof( event_info )
    def __iter__( self ):
        return CallsIterator( self )
        
cdef class CallsIterator:
    """Provide python-level iteration over a EventsFile"""
    def __cinit__( self, records ):
        self.records = records 
        self.position = 0
    def __next__( self ):
        if self.position < self.records.record_count:
            result = <object>(self.records.records[self.position])
            self.position += 1
            return result 
        raise StopIteration( self.position )

def byteswap_16( input ):
    return swap_16( input )
def byteswap_32( input ):
    return swap_32( input )
        
cdef uint16_t swap_16( uint16_t input ):
    """Byte-swap a 16-bit integer"""
    cdef uint16_t output 
    cdef uint16_t low_mask = 0x00ff 
    cdef uint16_t high_mask = 0xff00
    cdef uint16_t shift = 8
    output = ((input & low_mask) << shift) | ((input & high_mask) >> shift)
    return output
cdef uint32_t swap_32( uint32_t input ):
    """Byte-swap a 32-bit integer"""
    cdef uint32_t output 
    cdef uint32_t low_mask = 0x000000ff 
    cdef uint32_t low_mid_mask = 0x0000ff00
    cdef uint32_t high_mid_mask = 0x00ff0000
    cdef uint32_t high_mask = 0xff000000
    cdef uint32_t small_shift = 8
    cdef uint32_t big_shift = 24
    output = (
        (input & low_mask) << big_shift |
        (input & low_mid_mask) << small_shift | 
        (input & high_mid_mask) >> small_shift |
        (input & high_mask ) >> big_shift
    )
    return output
