import wx, random
from coldshot import stack, loader

class CallTree(wx.TreeCtrl):
    """Allows browsing of a call-tree from Coldshot
    """
    def __init__(self, *args, **kwargs):
        super(CallTree, self).__init__(*args, **kwargs)
        self.Bind(wx.EVT_TREE_ITEM_EXPANDING, self.OnExpandItem)
        self.loader = loader.Loader( '.profile', individual_calls=set([1]))
        self.loader.load()
        self.rootID = self.AddRoot('Functions')
        self.SetPyData( self.rootID, self.loader.info )
        self.SetItemHasChildren(self.rootID)
        self.Expand( self.rootID )

    def OnExpandItem(self, event):
        item = event.GetItem()
        node = self.GetPyData( item )
        if isinstance( node, stack.LoaderInfo ):
            # children are functions 
            cid,citem = self.GetFirstChild(item)
            if not cid.IsOk():
                # not already filled out
                functions = node.functions.values()
                functions.sort( key = lambda x: (x.cumulative,x.name))
                for function in functions:
                    function_id = self.AppendItem( item, '%s.%s'%( function.module, function.name ))
                    self.SetPyData( function_id, function )
                    if function.individual_calls:
                        self.SetItemHasChildren( function_id )
        

class CallTreeFrame(wx.Frame):
    def __init__(self, *args, **kwargs):
        super(CallTreeFrame, self).__init__(*args, **kwargs)
        self.tree = CallTree( self )

if __name__ == "__main__":
    app = wx.App(False)
    frame = CallTreeFrame(None)
    frame.Show()
    app.MainLoop()
