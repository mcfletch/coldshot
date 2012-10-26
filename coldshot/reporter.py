class Reporter( object ):
    def __init__( self, loader, sort=('-time','module','name' )):
        self.loader = loader 
        self.set_sort( sort )
    def set_sort( self, sort ):
        """Set our sorting key"""
        def key(x):
            result = []
            for key in sort:
                if key.startswith( '-' ):
                    result.append( - (getattr(x,key[1:],0)))
                else:
                    result.append( getattr( x, key, None))
            return result 
        self.sort = key 
    def report( self ):
        functions = self.loader.functions.values()
        functions.sort( key=self.sort )
        COLSET = ['module','name','time','calls']
        header = '%s %s %s %s'%('Namespace'.rjust(30),'Name'.ljust(20),'Cumtime'.rjust(12),'Calls'.rjust(9))
        report = [ header, '' ]
        divisor = float(1000000)
        for function in functions:
            if function.time > 1000:
                report.append('''%s %s % 8.4f % 8d'''%(
                    function.module[-30:].rjust(30),
                    function.name.ljust(20),
                    function.time/divisor,
                    function.calls,
                ))
        return '\n'.join( report )
    
