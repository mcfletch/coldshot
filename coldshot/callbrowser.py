import wx, random
from coldshot import stack, loader

class CallTree(wx.TreeCtrl):
    """Allows browsing of a call-tree from Coldshot
    """
    def __init__(self, *args, **kwargs):
        super(CallTree, self).__init__(*args, **kwargs)
        self.Bind(wx.EVT_TREE_ITEM_EXPANDING, self.OnExpandItem)
        self.loader = loader.Loader( '.profile', individual_calls=set([('*','*')]))
        self.loader.load()
        self.rootID = self.AddRoot('Functions')
        self.SetPyData( self.rootID, self.loader.info )
        self.SetItemHasChildren(self.rootID)
        self.Expand( self.rootID )

    def HasChildren( self, item ):
        cid,citem = self.GetFirstChild(item)
        return cid.IsOk()
        
        
    def OnExpandItem(self, event):
        item = event.GetItem()
        node = self.GetPyData( item )
        if isinstance( node, stack.LoaderInfo ):
            # children are functions 
            if not self.HasChildren( item ):
                # not already filled out
                functions = node.functions.values()
                functions.sort( key = lambda x: (x.module,x.name))
                for function in functions:
                    self.AddFunction( item, function )
        elif isinstance( node, (stack.FunctionInfo, stack.CallInfo) ):
            # children are individual calls
            if not self.HasChildren( item ):
                if isinstance( node, stack.FunctionInfo):
                    calls = node.individual_calls[:]
                else:
                    calls = node.children
                for call in calls:
                    self.AddCall( item, call )
    def AddFunction(self, parent_id, function ):
        function_id = self.AppendItem( parent_id, '%s.%s'%( function.module, function.name ))
        self.SetPyData( function_id, function )
        if function.individual_calls:
            self.SetItemHasChildren( function_id )
        return function_id
    def AddCall( self, parent_id, call ):
        call_id = self.AppendItem( parent_id, '%0.5f [%s:%s] @ %s:%s -> %s.%s:%s'%( call.cumulative, call.start, call.stop, call.start_index, call.stop_index, call.function.module, call.function.name, call.function.line ))
        self.SetPyData( call_id, call )
        if call.children:
            self.SetItemHasChildren( call_id )
        return call_id
    
class CallTreeFrame(wx.Frame):
    def __init__(self, *args, **kwargs):
        super(CallTreeFrame, self).__init__(*args, **kwargs)
        self.tree = CallTree( self )

if __name__ == "__main__":
    app = wx.App(False)
    frame = CallTreeFrame(None)
    frame.Show()
    app.MainLoop()
