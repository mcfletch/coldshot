
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
        COLSET = ['module','name','time','calls','local']
        header = '%s %s %s %s %s'%('Namespace'.rjust(30),'Name'.ljust(20),'Cumtime'.ljust(12),'Calls'.ljust(9),'Local'.ljust(9))
        report = [ header, '' ]
        for function in functions:
            if function.time:
                report.append('''%s:%s %s % 8.4f % 8d % 8.4f'''%(
                    function.module[-30:].rjust(30),
                    str(function.line).ljust(4),
                    function.name.ljust(20),
                    function.time * self.loader.timerunit,
                    function.calls,
                    function.local_time * self.loader.timerunit,
                ))
                for (line,lineinfo) in sorted(function.line_map.items()):
                    report.append( '    % 5d % 8.4f % 8d'%(
                        lineinfo.line,
                        lineinfo.time * self.loader.timerunit,
                        lineinfo.calls,
                    ))
        return '\n'.join( report )
    
