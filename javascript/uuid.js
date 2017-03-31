// code based on: http://stackoverflow.com/questions/105034/create-guid-uuid-in-javascript

var globalObj = this;
globalObj['generateUUID'] = function generateUUID(){
    var d = new window['Date']()['getTime']();
    if(window['performance'] && typeof window['performance']['now'] === "function"){
        d += window['performance']['now'](); //use high-precision timer if available
    }
    var uuid = 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'['replace'](/[xy]/g, function(c) {
        var r = (d + window['Math']['random']()*16)%16 | 0;
        d = window['Math']['floor'](d/16);
        return (c=='x' ? r : (r&0x3|0x8))['toString'](16);
    });
    return uuid;
};
