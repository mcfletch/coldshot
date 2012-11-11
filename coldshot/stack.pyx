from coldshot cimport uint16_t, uint32_t
import os, logging 
log = logging.getLogger( __name__ )

cdef class LoaderInfo:
    """Summary of information loaded from a file
    
    functions -- id:FunctionInfo records
    
    function_names -- (module,function_name): FunctionInfo records
    
    files -- id:FileInfo records 
    
    file_names -- name:FileInfo records
    
    threads -- id:Stack records 
    
    roots -- string_key:root_object records
    
    modules -- id:ModuleInfo records
    
    timer_unit -- fractional multiplier for raw time
    
    bigendian -- whether the source file was written big-endian
    
    swapendian -- whether we need to swap the endianness of records
    """
    def __cinit__( self ):
        self.functions = {}
        self.function_names = {}
        self.files = {}
        self.file_names = {}
        self.annotations = {}
        self.annotation_notes = {}
        self.threads = {}
        self.roots = {}
        self.modules = {}
        
        self.individual_calls = set()
        
        self.timer_unit = .000001 # Linux default
        
        self.add_file('__builtin__', 0 )
        
        self.bigendian = False 
        self.swapendian = False
        
        self.add_function(self.add_root( 'calls', FunctionInfo( 
            0xffffffff, '*', '*',
            self.files[0],
            0,
            self
        )))
        module_root = PackageInfo( '', self )
        self.add_root( 'modules', module_root )
        self.modules[''] = module_root
        
    cdef FileInfo add_file( self, filename, uint16_t fileno ):
        """Add a new file record to the loader"""
        cdef FileInfo file = FileInfo( filename, fileno )
        self.files[ fileno ] = self.file_names[ filename ] = file 
        return file
    cdef FunctionInfo add_function( self, FunctionInfo function ):
        """Register a new function"""
        cdef Grouping module
        self.functions[ function.key ] = function 
        self.function_names[ (function.module,function.name) ] = function 
        module = self.add_module( function.module, function.path )
        module.children.append( function )
        return function
    cdef Stack add_thread( self, Stack stack ):
        self.threads[ stack.thread ] = stack
        return stack 
    cdef add_root( self, key, root ):
        self.roots[ key ] = root 
        return root 
    def get_root( self, key ):
        """Get the given root, raise KeyError if not defined"""
        return self.roots[key]
    def parents_of( self, FunctionInfo child ):
        """Retrieve those functions who are parents of functioninfo"""
        cdef FunctionInfo possible 
        result = []
        for possible in self.functions.itervalues():
            if child.key in possible.child_map:
                result.append( possible )
        return result 
    def rows( self ):
        """Produce the set of all rows"""
        return self.functions.values()
    cdef Annotation add_annotation( self, uint32_t id, str raw ):
        """Add an annotation to the information records"""
        cdef Annotation note = Annotation( raw, raw, self )
        self.annotations[id] = note
        self.annotation_notes[raw] = note
        return note
    cdef Grouping add_module( self, module_name, path ):
        """Add a module to our set of defined modules"""
        cdef list fragments 
        cdef object last, current
        current = self.modules.get( module_name )
        if current is not None:
            # short circuit since we've already created it...
            return current 
        fragments = module_name.split('.')
        last = None
        current = None
        for i in range( len(fragments)+1):
            name = '.'.join( fragments[:i] )
            current = self.modules.get( name )
            if current is None:
                if name == module_name:
                    self.modules[name] = current = ModuleInfo( name, path, self )
                else:
                    self.modules[name] = current = PackageInfo( name, self )
                if last is not None:
                    last.children.append( current )
            last = current 
        return current
    def function_rows( self ):
        """Get cProfile-like function metadata rows
        
        returns an ID: function mapping
        """
        return self.functions
    def location_rows( self ):
        """Get our location records (finalized)
        
        returns an module-name: Grouping mapping
        """
        result = self.modules.items()
        result.sort(reverse=True)
        for key,module in result:
            module.calculate_totals()
        return self.modules

cdef class Stack:
    """Stack builds models of the run-time functions during loading (for a single thread)
    
    Attributes:
    
        thread -- 16-bit thread id
        loader -- LoaderInfo object
        start -- 32-bit timestamp for first event in the thread
        stop -- 32-bit timestamp for the last event in the thread
        context_switches -- counter of the number of context switches observed
    
    TODO: need to have "children" for the stack (thread) to show us what was run 
    during the thread
    """
    def __cinit__( self, uint16_t thread, uint32_t timestamp, LoaderInfo loader, FunctionInfo root ):
        self.thread = thread
        self.loader = loader
        self.start = timestamp 
        self.stop = timestamp
        self.context_switches = 0
        self.individual_calls = ('*','*') in loader.individual_calls
        
        self.function_stack = []
        self.push( root, timestamp, -1 )
    
    cdef record_context_switch( self, uint32_t timestamp ):
        """Record the fact that a context switch has occurred"""
        self.context_switches += 1
    cdef debug_stack( self ):
        """Print out a debug stack trace during loading"""
        cdef CallInfo call_info
        if self.function_stack:
            call_info = self.function_stack[-1]
            print call_info.start_index, call_info
            for i,call_info in enumerate(self.function_stack):
                print '%05i %s%s.%s'%(
                    call_info.start_index, 
                    ' '*(i+1),
                    call_info.function.module, 
                    call_info.function.name 
                )
    cdef annotation( self, uint32_t id, uint32_t timestamp, uint16_t lineno ):
        """Record a new annotation
        
        id -- annotation id
        timestamp -- 32-bit timestamp,currently ignored
        lineno -- line number (arbitrary data)
        """
        self.current_annotation = <Annotation>self.loader.annotations.get( id )
        # TODO: needs to be configurable...
        
    cdef push( self, FunctionInfo function_info, uint32_t timestamp, long index ):
        """Push a new record onto the function stack"""
        call_info = CallInfo( function_info, timestamp, index, self.thread )
        self.function_stack.append( call_info )
        if function_info.key in function_info.loader.individual_calls:
            self.individual_calls += 1
        if self.individual_calls:
            function_info.individual_calls.append( call_info )
        # TODO: allow annotation to decide what to do with events...
        if self.current_annotation is not None:
            self.current_annotation.children.append( call_info )
    cdef pop( self, uint32_t timestamp, long index ):
        """Pop a single record from the stack at given timestamp"""
        cdef CallInfo call_info 
        cdef uint32_t current_function 
        
        call_info = <CallInfo>(self.function_stack[-1])
        call_info.record_line( call_info.function.line, timestamp )
        current_function = call_info.function.key 
        child_delta = call_info.record_stop( timestamp, index )
        self.stop = timestamp

        if current_function in call_info.function.loader.individual_calls:
            self.individual_calls -= 1
        
        del self.function_stack[-1]
        if self.function_stack:
            call_info = self.function_stack[-1]
            # child is current_function...
            call_info.record_stop_child( child_delta, current_function )
    cdef line( self, uint16_t line, uint32_t timestamp ):
        """Record a line event into the stack trace"""
        cdef CallInfo call_info = self.function_stack[-1]
        return call_info.record_line( line, timestamp )
    
cdef class FileInfo:
    """Referenced by functions which declare the same file
    
    All built-in functions currently declare the same file number (0), so all 
    built-ins will appear to come from a single file.
    """
    def __init__( self, path, fileno ):
        self.path = path
        self.directory, self.filename = os.path.split( path )
        self.fileno = fileno 
    def __unicode__( self ):
        return '<%s for %s>'%( self.__class__.__name__, self.filename )
    __repr__ = __unicode__

cdef class FunctionInfo:
    """Represents call/trace information for a single function
    
    Attributes of note:
    
        key -- ID/Key used in the trace to identify this function
        module -- name of the module and class (x.y.z)
        name -- name of the function/method
        file -- FileInfo for the module, note: builtins all use the same FileInfo
        line -- line on which the function begins 
        loader -- reference to the loader which created us...
        
        calls -- count of calls on the function 
        time -- cumulative time spent in the function
        child_time -- cumulative time spent in children
        line_map -- line: FunctionLineInfo mapping for each line executed
        child_map -- child_id: cumulative-time for each called child...
        
        first_timestamp -- timestamp of the first call to the function
        last_timestamp -- timestamp of the last call to the function
    
    All times/timestamps are stored in the original profiler units.
    """
    def __init__( self, uint32_t key, str module, str name, FileInfo file, uint16_t line, LoaderInfo loader ):
        """Initialize the FunctionInfo instance"""
        self.loader = loader
        self.key = key
        
        self.module = module 
        self.name = name 
        self.file = file
        self.line = line
        
        self.line_map = {}
        self.child_map = {}
        self.individual_calls = []
        
        self.time = 0
        self.calls = 0
        self.child_time = 0
        self.first_timestamp = 0
        self.last_timestamp = 0
    
    # external data-API showing seconds 
    @property 
    def local( self ):
        if self.time and self.time >= self.child_time:
            return (self.time - self.child_time) * self.loader.timer_unit
        else:
            return 0.0
    @property 
    def empty( self ):
        """Calculate local time as a fraction of total time"""
        if self.time and self.time >= self.child_time:
            return (self.time - self.child_time)/float( self.time )
        return 0.0
    @property 
    def cumulative( self ):
        """Cumulative time in seconds"""
        return self.time * self.loader.timer_unit
    @property 
    def localPer( self ):
        """Average local time in seconds per call"""
        return self.local / ( self.calls or 1 )
    @property 
    def cumulativePer( self ):
        """Average cumulative time in seconds per call"""
        return self.cumulative / (self.calls or 1 )
    
    @property 
    def lineno( self ):
        return self.line 
    @property 
    def filename( self ):
        return self.file.filename 
    @property 
    def directory( self ):
        return self.file.directory 
    @property 
    def path( self ):
        return self.file.path
    @property
    def parents( self ):
        """Retrieve those functions which directly call me"""
        return self.loader.parents_of(self)
    @property
    def sorted_children( self ):
        """Retrieve our children records from our loader in time-sorted order
        
        returns [(cumtime,otherfunc), ... ] for all of our called children
        """
        children = [(v,self.loader.functions.get(k)) for (k,v) in self.child_map.items() if k != self.key]
        children.sort()
        return children
    @property 
    def children( self ):
        return [x[1] for x in self.sorted_children]
    def child_cumulative_time( self, other ):
        """Return cumulative time spent in other as a fraction of our cumulative time"""
        return self.child_map.get(other.key, 0)/float( self.time or 1 )
        
    # Internal APIs for Loader
    cdef record_call( self, uint32_t timestamp ):
        """Increment our internal call counter and first/last timestamp"""
        self.calls += 1
        if not self.first_timestamp:
            self.first_timestamp = timestamp
        self.last_timestamp = timestamp
    cdef record_time_spent( self, uint32_t delta ):
        """Record total time spent in the function (cumtime)"""
        self.time += delta 
    cdef record_time_spent_child( self, uint32_t child, uint32_t delta ):
        """Record time spent in a given child function"""
        cdef long current
        if child != self.key:
            # we don't consider time in ourselves to be a child...
            self.child_time += delta 
        current = self.child_map.get( child, 0 )
        self.child_map[child] = current + delta
    
    def __repr__( self ):
        return '<%s %s:%s %s:%ss>'%(
            self.__class__.__name__,
            self.module,
            self.name,
            self.calls,
            self.cumulative,
        )

cdef class FunctionLineInfo:
    """Timing of a single line within a function"""
    def __cinit__( self, uint16_t line ):
        self.line = line 
        self.time = 0
        self.calls = 0
    cdef add_time( self, uint32_t delta, int exit ):
        """Add time spent on the line"""
        self.time += delta 
        if not exit:
            self.calls += 1
    def __repr__( self ):
        return b'Line %s: %s %.4fs'%( self.line, self.calls, self.time, )

cdef class CallInfo:
    """Tracks information related to a single Stack Frame
    
    if loader.individual_calls is True, then we will save these objects 
    so that the CallInfo records are available
    
    Otherwise is just used by the stack to track calls during initial loading.
    """
    def __init__( self, FunctionInfo function, uint32_t start, long start_index, uint16_t thread ):
        self.function = function 
        self.thread = thread
        self.last_line_time = self.stop = self.start = start 
        self.last_line = function.line
        self.start_index = start_index
        self.stop_index = start_index
        self._children = None
    def __repr__( self ):
        return '<%s for %s at index %s %ss:%ss>'%(
            self.__class__.__name__,
            self.function,
            self.start_index,
            self.start * self.function.loader.timer_unit,
            self.stop * self.function.loader.timer_unit,
        )
    cdef public uint32_t record_stop( self, uint32_t stop, long stop_index ):
        """Record a stop event (call has stopped) event"""
        cdef uint32_t delta = stop - self.start 
        self.stop = stop
        self.stop_index = stop_index
        self.function.record_call(self.start)
        self.function.record_time_spent( delta )
        return delta
    cdef public uint32_t record_stop_child( self, uint32_t delta, uint32_t child ):
        """Child has exited, record time spent in the child"""
        self.function.record_time_spent_child( child, delta )
        
    cdef uint32_t record_line( self, uint16_t new_line, uint32_t stop ):
        """Record time spent on a given line"""
        cdef FunctionLineInfo current = self.function.line_map.get( self.last_line, None )
        cdef uint32_t delta = stop-self.last_line_time
        if current is None:
            self.function.line_map[self.last_line] = current = FunctionLineInfo( self.last_line )
        current.add_time( delta, 0 )
        self.last_line = new_line 
        self.last_line_time = stop 
        return delta
    @property 
    def time( self ):
        return self.stop - self.start 
    @property 
    def empty( self ):
        if self.time > self.child_time:
            return (self.time - self.child_time) / float( self.time or 1 )
        return 0.0
    @property 
    def local( self ):
        if self.time > self.child_time:
            return (self.time - self.child_time) * self.function.loader.timer_unit
        return 0.0
    @property 
    def localPer( self ):
        return self.local / float(self.calls or 1)
    @property 
    def cumulative( self ):
        return self.time * self.function.loader.timer_unit 
    @property 
    def cumulativePer( self ):
        return self.cumulative / float( self.calls or 1)
    @property 
    def child_time( self ):
        if self._children is None:
            self.scan_children()
        return self._child_time
    @property 
    def filename( self ):
        return self.function.file.filename 
    @property 
    def directory( self ):
        return self.function.file.directory 
    @property 
    def path( self ):
        return self.function.file.path
    @property 
    def children( self ):
        """Children of a particular call 
        
        Return sequence of CallInfo records where:
        
            call_info.function.key in self.function.child_map.keys
            call_info.thread == self.thread 
            call_info.start_index > self.start_index 
            call_info.stop_index < self.stop_index 
        
        However, that does not take into account recursive calls to the same 
        function, so we need to prune out such that we have no *overlapping* 
        calls, that is, once we have the first (lowest) call, we need to remove 
        anything that is within that call which falls within our set, and do 
        that for each of the top-level calls found...
        """
        # TODO: needs cache
        if self._children is None:
            self.scan_children()
        return self._children
    def scan_children( self ):
        """Scan our children and find recursive call events"""
        cdef FunctionInfo other_func
        cdef CallInfo call_info
        cdef list possible
        cdef uint32_t child_time = 0
        possible = []
        for other in self.function.child_map.keys():
            other_func = self.function.loader.functions[other]
            for call_info in other_func.individual_calls:
                if call_info.thread == self.thread:
                    if call_info.start_index > self.start_index and call_info.stop_index < self.stop_index:
                        possible.append( (call_info.start_index,call_info) )
        self._children = self._remove_overlaps( possible )
        for child in self._children:
            child_time += child.time 
        self._child_time = child_time
    def _remove_overlaps( self, list possible ):
        """Remove the overlaps from the list of possible values for children"""
        cdef list result
        cdef CallInfo next, first
        
        if possible:
            possible.sort( )
            first = possible[0][1]
            result = [ first ]
            for index,next in possible[1:]:
                if next.stop_index < first.stop_index:
                    continue 
                else:
                    result.append( next )
                    first = next 
        else:
            result = possible
        return result
    
cdef class Grouping:
    """Static grouping of elements for presentation"""
    def __init__( self, key, str name, LoaderInfo loader ):
        self.key = key
        self.name = name
        self.children = []
        self.loader = loader
        self.calls = 0
        self.cumulative = 0
        self.cumulativePer = 0
        self.local = 0
        self.localPer = 0.0
        self.empty = 0.0
    def child_cumulative_time( self, other ):
        """Return fraction of our time spent in other"""
        return other.cumulative / float( self.cumulative or 1 )
    def calculate_totals( self ):
        """Calculate totals from the sum of our children"""
        self.calls = sum( [x.calls for x in self.children], 0 )
        self.cumulative = sum( [x.cumulative for x in self.children], 0.0)
        self.cumulativePer = self.cumulative / float(self.calls or 1)
    def __repr__( self ):
        return '<%s %s %s:%ss>'%(
            self.__class__.__name__,
            self.key,
            self.calls,
            self.cumulative,
        )
    
cdef class PackageInfo( Grouping ):
    """Set of modules"""
    def __init__( self, str module, LoaderInfo loader ):
        if module:
            name = module
        else:
            name = '<PYTHONPATH>'
        Grouping.__init__( self, module, name, loader )
    @property 
    def parents( self ):
        """Determine who is our parent in the packaging hierarchy"""
        if not self.key:
            return []
        name = '.'.join( self.key.split('.')[:-1])
        parent = self.loader.modules.get( name )
        if parent:
            return [parent]
        return []
        
cdef class ModuleInfo( PackageInfo ):
    """A particular module (function.__module__)
    
    Only function-local time is included in cumulative, so the result is that 
    the text-of-the-module is what is represented into the representation.
    """
    def __init__( self, str module, str path, LoaderInfo loader ):
        self.path = path 
        self.directory, self.filename = os.path.split( path )
        
        Grouping.__init__( self, module, module, loader )
    def child_cumulative_time( self, other ):
        """Return fraction of our time spent in other"""
        return other.local / float( self.cumulative or 1 )
    def calculate_totals( self ):
        """Calculate our totals from our children (only counts function localtime)"""
        self.cumulative = sum( [x.local for x in self.children], 0.0)
        self.cumulativePer = self.cumulative / float(self.calls or 1)
        self.calls = sum( [x.calls for x in self.children], 0 )
    @property 
    def parents( self ):
        """Only ever one parent for a module"""
        if not self.key:
            return []
        name = '.'.join( self.key.split('.')[:-1])
        parent = self.loader.modules.get( name )
        if parent:
            return [parent]
        return []

cdef class Annotation( Grouping ):
    """Grouping of calls/records with a given annotation"""
    
