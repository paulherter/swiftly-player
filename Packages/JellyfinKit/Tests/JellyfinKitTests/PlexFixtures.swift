import Foundation

/// Answers as a Plex server and plex.tv write them, cut down to what the tests need.
/// Shapes were measured against a real server; every token here is made up.
enum PlexFixtures {

    static let movie = #"""
    {"MediaContainer":{"size":1,"Metadata":[{
      "ratingKey":"1","type":"movie","title":"Testfilm","titleSort":"Testfilm","year":"2020",
      "studio":"Bonobostudio","tagline":"Short line","contentRating":"de/12","summary":"A film.",
      "audienceRating":7.5,"rating":8.0,"userRating":10,"duration":90023,"viewOffset":45011,
      "viewCount":0,"lastViewedAt":1700000000,"originallyAvailableAt":"2020-01-25",
      "thumb":"/library/metadata/1/thumb/17","art":"/library/metadata/1/art/17",
      "Image":[{"alt":"Logo","type":"clearLogo","url":"/library/metadata/1/clearLogo/17"}],
      "Media":[
        {"id":1,"duration":90023,"container":"mkv","videoResolution":"4k","Part":[
          {"id":1,"key":"/library/parts/1/1793487178/file.mkv","duration":90023,
           "file":"/media/Filme/Testfilm.mkv","size":30165745,"container":"mkv","indexes":"sd",
           "Stream":[
            {"id":1,"streamType":1,"codec":"HEVC","index":0,"height":2160,"width":3840,
             "frameRate":23.976,"colorTrc":"smpte2084","DOVIPresent":true,"DOVIProfile":8,
             "DOVIBLCompatID":1},
            {"id":2,"streamType":2,"selected":true,"default":true,"codec":"eac3","index":1,
             "channels":6,"languageCode":"eng","displayTitle":"English (EAC3 5.1)"},
            {"id":3,"streamType":2,"codec":"aac","index":2,"channels":2,"languageCode":"deu",
             "displayTitle":"Deutsch (AAC Stereo)"},
            {"id":4,"streamType":3,"codec":"srt","index":3,"languageCode":"deu","forced":"1",
             "displayTitle":"Deutsch (SRT)","key":"/library/streams/4","format":"srt"},
            {"id":5,"streamType":3,"selected":true,"codec":"pgs","index":4,"languageCode":"eng",
             "displayTitle":"English (PGS)"}]}]},
        {"id":2,"duration":90023,"container":"mp4","videoResolution":"1080","Part":[
          {"id":2,"key":"/library/parts/2/1793487191/file.mp4","duration":90023,
           "file":"/media/Filme/Testfilm 1080.mp4","size":17228584,"container":"mp4",
           "Stream":[{"id":6,"streamType":1,"codec":"h264","height":1080,"width":1920}]}]}],
      "Genre":[{"id":"5","tag":"Action","filter":"genre=5"}],
      "Country":[{"tag":"USA"}],
      "Role":[{"id":"10","tag":"Ann Actor","role":"Neo","thumb":"https://metadata-static.plex.tv/a.jpg"}],
      "Director":[{"tag":"Bob Director"}],"Writer":[{"tag":"Cleo Writer"}],
      "Guid":[{"id":"imdb://tt0133093"},{"id":"tmdb://603"},{"id":"tvdb://78804"},{"id":"other://x"}],
      "Marker":[
        {"type":"intro","startTimeOffset":1000,"endTimeOffset":61000},
        {"type":"credits","startTimeOffset":85000,"endTimeOffset":120000,"final":true},
        {"type":"sponsor","startTimeOffset":5000,"endTimeOffset":6000}],
      "Chapter":[{"tag":"Start","startTimeOffset":0,"endTimeOffset":30000},
                 {"tag":"","startTimeOffset":30000,"endTimeOffset":90023}]
    }]}}
    """#

    static let episode = #"""
    {"MediaContainer":{"size":1,"Metadata":[{
      "ratingKey":"5","type":"episode","title":"Pilot","parentRatingKey":"4",
      "grandparentRatingKey":"3","grandparentTitle":"Test Show","parentTitle":"Season 1",
      "index":2,"parentIndex":1,"viewCount":1,"duration":60023,
      "thumb":"/library/metadata/5/thumb/1","grandparentThumb":"/library/metadata/3/thumb/1",
      "grandparentArt":"/library/metadata/3/art/1","parentThumb":"/library/metadata/4/thumb/1",
      "Media":[{"id":3,"Part":[{"id":3,"key":"/library/parts/3/1/file.mkv","container":"mkv"}]}]
    }]}}
    """#

    static let show = #"""
    {"MediaContainer":{"size":1,"Metadata":[{
      "ratingKey":"3","type":"show","title":"Test Show","leafCount":10,"viewedLeafCount":4,
      "childCount":2,"thumb":"/library/metadata/3/thumb/1","art":"/library/metadata/3/art/1"
    }]}}
    """#

    /// A page of a list: two entries of seven, one of them broken (no `ratingKey`).
    static let page = #"""
    {"MediaContainer":{"size":3,"totalSize":7,"offset":0,"Metadata":[
      {"ratingKey":"10","type":"movie","title":"One","year":2001},
      {"type":"movie","title":"Broken"},
      {"ratingKey":"11","type":"show","title":"Two","year":"2002"}]}}
    """#

    static let sections = #"""
    {"MediaContainer":{"size":3,"Directory":[
      {"key":"1","type":"movie","title":"Filme","uuid":"u1"},
      {"key":"2","type":"show","title":"Serien","uuid":"u2"},
      {"key":"3","type":"artist","title":"Musik","uuid":"u3"}]}}
    """#

    static let identity = #"""
    {"MediaContainer":{"size":0,"claimed":false,"machineIdentifier":"MACHINE1","version":"1.43.0.0"}}
    """#

    static let resources = #"""
    [
     {"name":"Home","clientIdentifier":"MACHINE1","provides":"server","owned":true,
      "accessToken":"SERVERTOKEN","httpsRequired":false,"presence":true,"ownerId":1,
      "connections":[
       {"protocol":"http","address":"192.168.1.5","port":32400,"uri":"http://192.168.1.5:32400","local":true,"relay":false,"IPv6":false},
       {"protocol":"https","address":"192.168.1.5","port":32400,"uri":"https://192-168-1-5.abc.plex.direct:32400","local":true,"relay":false,"IPv6":false},
       {"protocol":"https","address":"84.1.2.3","port":32400,"uri":"https://84-1-2-3.abc.plex.direct:32400","local":false,"relay":false,"IPv6":false},
       {"protocol":"https","address":"10.0.0.1","port":8443,"uri":"https://10-0-0-1.abc.plex.direct:8443","local":false,"relay":true,"IPv6":false}]},
     {"name":"Friend","clientIdentifier":"MACHINE2","provides":"server","owned":false,
      "accessToken":"FRIENDTOKEN","connections":[]},
     {"name":"Phone","clientIdentifier":"PHONE","provides":"client,player","owned":true,"connections":[]}
    ]
    """#

    static let pinFresh = #"""
    {"id":4711,"code":"ABCD1234","product":"Swiftly Player","trusted":false,"qr":"https://plex.tv/api/v2/pins/qr/ABCD1234","clientIdentifier":"cid","expiresIn":1800,"authToken":null}
    """#
    static let pinDone = #"""
    {"id":4711,"code":"ABCD1234","expiresIn":1700,"authToken":"ACCOUNTTOKEN"}
    """#

    static let homeUsers = #"""
    {"id":99,"name":"Home","users":[
      {"id":1,"uuid":"uuid-admin","title":"Owner","admin":true,"restricted":false,"protected":false,"guest":false},
      {"id":2,"uuid":"uuid-kid","title":"Kid","admin":false,"restricted":true,"protected":true,"guest":false}]}
    """#
}
