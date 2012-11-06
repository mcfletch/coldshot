from coldshot cimport uint16_t, uint32_t

cdef class LoaderInfo:
    cdef public dict functions 
    cdef public dict function_names 
    cdef public dict files 
    cdef public dict file_names
    cdef public bint bigendian
    cdef public bint swapendian
    cdef public double timer_unit
    cdef public dict threads
    cdef public dict roots
    cdef public set individual_calls
    cdef public dict modules
    
    cdef FileInfo add_file( self, filename, uint16_t fileno )
    cdef FunctionInfo add_function( self, FunctionInfo function )
    cdef Stack add_thread( self, Stack stack )
    cdef object add_root( self, key, root )
    cdef Grouping add_module( self, module_name, path )

cdef class Stack:
    cdef public uint16_t thread 
    cdef public LoaderInfo loader
    cdef public uint32_t start 
    cdef public uint32_t stop 
    cdef public long context_switches
    cdef list function_stack
    cdef uint16_t individual_calls
    
    cdef push( self, FunctionInfo function_info, uint32_t timestamp, long index )
    cdef pop( self, uint32_t timestamp, long index )
    cdef line( self, uint16_t line, uint32_t timestamp )
    cdef record_context_switch( self, uint32_t timestamp )

cdef class Row:
    """Base class for all profile-row types"""
    cdef public long calls 
    cdef public long time
    cdef public long child_time
    cdef public LoaderInfo loader 
cdef class FunctionInfo(Row):
    cdef public uint32_t key
    cdef public str module 
    cdef public str name 
    cdef public FileInfo file
    cdef public uint16_t line
    
    cdef public long first_timestamp
    cdef public long last_timestamp
    
    cdef public dict line_map 
    cdef public dict child_map
    cdef public list individual_calls
    cdef record_call( self, uint32_t timestamp )
    cdef record_time_spent( self, uint32_t delta )
    cdef record_time_spent_child( self, uint32_t child, uint32_t delta )

cdef class FunctionLineInfo:
    cdef public uint16_t line 
    cdef public uint32_t time 
    cdef public uint32_t calls
    cdef add_time( self, uint32_t delta, int exit )

cdef class FileInfo:
    """Referenced by functions which declare the same file
    
    All built-in functions currently declare the same file number (0), so all 
    built-ins will appear to come from a single file.
    """
    cdef uint16_t fileno 
    cdef public object filename 
    cdef public object directory
    cdef public object path 
    cdef public LoaderInfo loader
    cdef object _children

cdef class CallInfo:
    cdef FunctionInfo function 
    cdef uint16_t thread
    cdef uint32_t start 
    cdef uint32_t stop
    cdef long start_index
    cdef long stop_index
    cdef list _children
    cdef uint32_t _child_time
    
    cdef uint16_t last_line 
    cdef uint32_t last_line_time
    cdef uint32_t record_stop( self, uint32_t stop, long stop_index )
    cdef uint32_t record_stop_child( self, uint32_t delta, uint32_t child )
    cdef uint32_t record_line( self, uint16_t new_line, uint32_t stop )
    
cdef class Grouping:
    cdef public object key
    cdef public object name
    cdef public LoaderInfo loader
    
    cdef public list children 
    
    cdef public long calls
    cdef public float cumulative 
    cdef public float cumulativePer
    cdef public float local 
    cdef public float empty 
    cdef public float localPer

cdef class PackageInfo( Grouping ):
    pass
cdef class ModuleInfo( PackageInfo ):
    cdef public object path
    cdef public object directory 
    cdef public object filename 
