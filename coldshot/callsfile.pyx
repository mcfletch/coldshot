"""Load/map/iterate over a data-file on disk"""
import os, mmap, logging
from coldshot cimport event_info, mmap_object
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
    
cdef class CallsFile(MappedFile):
    """Particular mapped file which loads our callsfile data-structures"""
    def get_pointer( self, mm ):
        cdef mmap_object * c_level
        c_level = <mmap_object *>mm
        self.records = <event_info *>(c_level[0].data)
        self.record_count = self.filesize // sizeof( event_info )
    def __iter__( self ):
        return CallsIterator( self )
        
cdef class CallsIterator:
    """Provide python-level iteration over a CallsFile"""
    def __cinit__( self, records ):
        self.records = records 
        self.position = 0
    def __next__( self ):
        if self.position < self.records.record_count:
            result = <object>(self.records.records[self.position])
            self.position += 1
            return result 
        raise StopIteration( self.position )
