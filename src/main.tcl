package require uuid
package require sqlite3
package require sha256

set script_path [ file dirname [ file normalize [ info script ] ] ]

source $script_path/wapp.tcl
source $script_path/utils.tcl

# Default port:
set port 8080

# Default base url:
set baseurl "http://localhost:$port"

# Default db file:
set dbfile $script_path/../doomtown.sqlite

# Default path to files:
set files_path [file normalize $script_path/../files]

# Default admin key:
set adminkey ""

# Parse start arguments:
set n [llength $argv]
for {set i 0} {$i<$n} {incr i} {
  set term [lindex $argv $i]
  if {[string match --* $term]} {set term [string range $term 1 end]}
  switch -glob -- $term {
    -port {
      incr i;
      set port [lindex $argv $i]
    }
    -db {
      incr i;
      set dbfile [lindex $argv $i]
    }
    -files {
      incr i;
      set files_path [lindex $argv $i]
    }
    -adminkey {
      incr i;
      set adminkey [lindex $argv $i]
    }
    -baseurl {
      incr i;
      set baseurl [lindex $argv $i]
    }
  }
}

if {$adminkey eq ""} {
  puts "WARNING: No admin key set."
}

# Setup subdirs in files path:
set upload_path $files_path/upload
set static_path $files_path/static
file mkdir $upload_path
file mkdir $static_path

# Args for wapp server:
set wapp_args [list --server $port]

sqlite3 db $dbfile
# Enable otherwise "ON DELETE CASCADE" will not work:
db eval "PRAGMA foreign_keys = ON;"

proc setup-db {} {
  global script_path
  set fp [open "$script_path/schema.sql" r]
  set schema [read $fp]
  close $fp
  db eval $schema
}

GET /contact {
  layout {
    wapp-subst {<h2>Kontakt</h2>}
    wapp-trim {
      <p>Krispin <a href="mailto:krispin@posteo.de">krispin@posteo.de</a></p>
    }
  }
}

GET /files {
  layout {
    wapp-allow-xorigin-params
    wapp-subst {<h2>Dateien</h2>}
    set query "SELECT hash, name, created_at FROM files"
    set search [wapp-param search]
    if {$search != ""} {
      set query "$query WHERE name LIKE '%$search%'"
    }
    # Search form:
    wapp-trim {
      <form method="GET">
        <input type="text" name="search" value="%html($search)"/>
        <input type="submit" value="Suchen" />
      </form>
    }
    wapp-subst {<ul>}
    set query "$query ORDER BY created_at DESC"
    db eval $query {
      wapp-trim {
        <li>%html($created_at) <a href="%url(/files/$hash)">%html($name)</a></li>
      }
    }
    wapp-subst {</ul>}
  }
}

GET /apps {
  layout {
    wapp-subst {<h2>Programme</h2>}
    wapp-trim {
      <p>Ein Programm ist eine HTML-Datei. Die Datei kann Javascript und CSS enthalten.</p>
    }
    wapp-subst {<ul>}
    set query "SELECT hash, name, title, description FROM files WHERE type = 'text/html' ORDER BY name ASC"
    db eval $query {
      set display $name
      if {$title != ""} {
        set display $title
      }
      if {$description != ""} {
        set description " - $description"
      }
      wapp-trim {
        <li><a href="%url(/files/raw/$hash)" target="_blank">%html($display)</a>%html($description)</li>
      }
    }
    wapp-subst {</ul>}
  }
}

POST /files/update {
  set file_hash [wapp-param file_hash]
  set title [wapp-param title]
  set description [wapp-param description]
  set row [db eval "UPDATE files SET title = '$title', description = '$description' WHERE hash = '$file_hash'"]
  # puts $row
  wapp-redirect /files/$file_hash
}

POST /files/delete {
  set file_hash [wapp-param file_hash]
  set row [db eval "SELECT hash, extension FROM files WHERE hash == '$file_hash'"]
  lassign $row hash extension
  set path [get_file_path $hash $extension]
  file delete -force $path
  db eval "DELETE FROM files WHERE hash == '$hash'"
  wapp-redirect /files
}

GET /files/raw/:hash {
  # TODO: secure with better CSP
  wapp-content-security-policy off
  set file_hash [dict get [wapp-param PATH_PARAMS] hash]
  set row [get-file $file_hash]
  if {[llength $row] == 0} {
    wapp-subst {<p>File not found.</p>}
    return
  } else {
    lassign $row hash name title description type extension tags
    set path [get_file_path $hash $extension]
    # Response raw file:
    wapp-reset
    wapp-mimetype "$type; charset=UTF-8"
    if [string match "text/*" $type] {
      wapp-unsafe [loadTextFile $path]
    } else {
      wapp-unsafe [loadBinaryFile $path]
    }
  }
}

# Save apps:
POST /files/raw/:hash {
  set file_hash [dict get [wapp-param PATH_PARAMS] hash]
  set row [get-file $file_hash]
  if {[llength $row] == 0} {
    wapp-subst {<p>File not found.</p>}
    return
  } else {
    lassign $row hash name title description type extension tags
    set content [wapp-param file]
    if {$content != ""} {
      update-raw-file $file_hash $content
    }
  }
}

GET /files/:hash {
  layout {
    wapp-allow-xorigin-params
    # puts [wapp-debug-env]
    set file_hash [dict get [wapp-param PATH_PARAMS] hash]
    set row [get-file $file_hash]
    if {[llength $row] == 0} {
      wapp-subst {<p>Datei nicht gefunden.</p>}
      return
    } else {
      lassign $row hash name title description type extension tags
      set path [get_file_path $hash $extension]
      # Show file details:
      wapp-subst {<h2>Datei</h2>}
      if {[string match image/* $type]} {
        wapp-subst {<a href="/files/raw/%html($file_hash)">}
          imageAsBase64 $type [loadBinaryFile $path]
        wapp-subst {</a>}
      }
      if {[string match text/* $type]} {
        set content [loadTextFile $path]
        show-text $content
      }
      if {[string match audio/* $type]} {
        show-audio $type /files/raw/$file_hash
      }
      wapp-trim {
        <form method="POST" action="/files/update">
          <input type="hidden" name="file_hash" value="%html($file_hash)"/>
          <p>
            Name: %html($name)<br/>
            Typ: %html($type)<br/><br/>
            Titel:<br/>
            <input name="title" type="text" value="%html($title)"/><br/>
            Beschreibung:<br/>
            <textarea name="description">%html($description)</textarea><br/><br/>
            <input type="submit" value="Speichern" />
          </p>
        </form>
      }
      wapp-subst {<p>Stichwörter:&nbsp;}
      foreach {tag} [split [lsort $tags] " "] {
        wapp-trim {
          <a href="">%html($tag)</a>&nbsp;
        }
      }
      wapp-subst {</p>}
      wapp-trim {
        <form method="POST" action="/tags">
          <input type="hidden" name="file_hash" value="%html($file_hash)"/>
          <input type="text" name="tags" value=""/>
          <input type="submit" value="Stichwörter hinzufügen" />
          <p>Es können mehrere Stichwörter durch Leerzeichen getrennt eingegeben werden.</p>
        </form>
      }
      if {[is_admin]} {
        wapp-trim {
          <form method="POST" action="/files/delete">
            <input type="hidden" name="file_hash" value="%html($file_hash)"/>
            <input class="red" type="submit" value="Datei löschen" />
          </form>
        }
      }
      wapp-trim {
        <p>
          <a href="/files/raw/%html($file_hash)" target="_blank">Datei anschauen</a>
        </p>
      }
    }
  }
}

GET /tags {
  layout {
    wapp-subst {<h2>Stichwörter</h2>}
    set query "SELECT id, name FROM tags"
    set search [wapp-param search]
    if {$search != ""} {
      set query "$query WHERE name LIKE '%$search%'"
    }
    # Search form:
    wapp-trim {
      <form method="GET">
        <input type="text" name="search" value="%html($search)"/>
        <input type="submit" value="Suchen" />
      </form>
    }
    wapp-subst {<ul>}
    set query "$query ORDER BY name ASC"
    db eval $query {
      wapp-trim {
        <li><a href="%url(/tags/$id)">%html($name)</a></li>
      }
    }
    wapp-subst {</ul>}
  }
}

proc is_admin {} {
  global adminkey
  # puts [wapp-debug-env]
  return [expr {$adminkey eq [wapp-param adminkey]}]
}

proc get_file_path {file_hash file_extension} {
  global upload_path
  return $upload_path/$file_hash.$file_extension
}

GET /tags/:id {
  layout {
    wapp-allow-xorigin-params
    set tag_id [dict get [wapp-param PATH_PARAMS] id]

    if {[is_admin]} {
      wapp-trim {
        <form method="POST" action="/tags/delete">
          <input type="hidden" name="tag_id" value="%html($tag_id)"/>
          <input type="submit" class="red" value="Stichwort löschen" />
        </form>
      }
    }

    set query "
      SELECT tags.name, files.hash, files.name
      FROM tags
      JOIN files_tags ON tags.id = files_tags.tag_id 
      JOIN files ON files.hash = files_tags.file_hash
      WHERE tags.id == '$tag_id'
    "
    set rows [db eval $query]
    if {[llength $rows] == 0} {
      wapp-subst {<p>Keine Dateien zu diesem Stichwort gefunden.</p>}
    } else {
      set tag_name ""
      wapp-trim {
        <h2>Stichwort '%html([lindex $rows 0])'</h2>
      }
      wapp-subst {<p>Dateien mit diesem Stichwort:</p>}
      wapp-subst {<ul>}
      foreach {tag_name file_hash file_name} $rows {
        wapp-trim {
          <li><a href="%url(/files/$file_hash)">%html($file_name)</a></li>
        }
      }
      wapp-subst {</ul>}
    }
  }
}

POST /tags/delete {
  set tag_id [wapp-param tag_id]
  set row [db eval "SELECT id,name FROM tags WHERE id == '$tag_id'"]
  lassign $row id name
  db eval "DELETE FROM tags WHERE id == '$tag_id'"
  wapp-redirect /tags
}

POST /tags {
  set file_hash [wapp-param file_hash]
  if { $file_hash == ""} {
    layout {
      wapp-subst {No file_hash given.}
    }
  } else {
    set tags [split [wapp-param tags] " "]
    foreach {tag} $tags {
      add-tag $tag $file_hash
    }
    wapp-redirect "/files/$file_hash"
  }
}

GET /upload {
  layout {
    wapp-trim {
      <h2>Upload</h2>
      <form method="POST" enctype="multipart/form-data">
        <p>
          Datei auswählen: <input type="file" name="file" />
        </p>
        <p>
          <input type="submit" value="Hochladen" />
        </p>
      </form>
    }
  }
}

POST /upload {
  # File upload query parameters come in three parts:  The *.mimetype,
  # the *.filename, and the *.content.
  set mimetype [wapp-param file.mimetype {}]
  set filename [wapp-param file.filename {}]
  set content [wapp-param file.content {}]
  if {$filename!=""} {
    set hash [add-file $filename $mimetype $content]
    if {$hash!=""} {
      # add first part of mimetype as tag otherwise group_concat will not work:
      add-tag [lindex [split $mimetype '/'] 0] $hash
      wapp-redirect "/files/$hash"
    }
  }
}

HEAD /rss {
  wapp-reset
  wapp-mimetype "text/xml; charset=utf-8"
}

GET /rss {
  global baseurl
  set query "SELECT hash, name, title, extension, type, description, created_at FROM files ORDER BY created_at DESC LIMIT 10"
  wapp-reset
  wapp-mimetype "text/xml; charset=utf-8"
  wapp-trim {
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/" xmlns:atom="http://www.w3.org/2005/Atom">
      <channel>
        <title>doomtown cottbus</title>
        <description>Neue Dateien als RSS-Feed</description>
        <link>%url($baseurl)</link>
        <lastBuildDate>Mon, 6 Sep 2010 00:01:00 +0000</lastBuildDate>
        <pubDate>Sun, 6 Sep 2009 16:20:00 +0000</pubDate>
        <ttl>1800</ttl>
  }
  db eval $query {
    set item_title $title
    set item_description $description
    if { $item_title == ""} {
      set item_title $name
    }
    if { $item_description == "" && [string match text/plain $type]} {
      set path [get_file_path $hash $extension]
      set item_description [loadTextFile $path]
    }

    wapp-trim {
      <item>
        <title>%html($item_title)</title>
        <description><!\[CDATA\[%html($item_description)\]\]></description>
        <link>%url($baseurl)%url(/files/$hash)</link>
        <guid>%url($baseurl)%url(/files/$hash)</guid>
        <pubDate>%html($created_at)</pubDate>
        <media:content url="%url($baseurl)%url(/files/raw/$hash)" medium="image" type="%html($type)" />
        <atom:link href="%url($baseurl)%url(/files/$hash)" hreflang="de"/>
      </item>
    }
  }
  wapp-subst {</channel></rss>}
}

proc wapp-default {} {
  layout {
    wapp-trim {
      <h2>Willkommen in Doomtown</h2>
      <p>
        Dies ist ein lokales Netzwerk, ohne Verbindung zum Internet.
        Es wird nur über einen mobilen WLAN-Router bereitgestellt.
        Der Router taucht ab und zu einfach so in der Stadt auf.
        Du kannst anonym Dateien hochladen und sie bleiben für die Nachwelt erhalten.
        Schreibe Texte, lade Bilder hoch oder suche nach Dateien von anderen Menschen.
      </p>
    }
  }
}

proc get-file {hash} {
  # Get file details and will only work if at least 1 tag is present:
  set row [db eval "
    SELECT files.hash, files.name, files.title, files.description, files.type, files.extension, GROUP_CONCAT(tags.name,' ') AS tags
    FROM files
    JOIN files_tags ON files.hash = files_tags.file_hash 
    JOIN tags ON tags.id = files_tags.tag_id
    WHERE files.hash == '$hash'
    GROUP BY files.hash
    ORDER BY files.hash;
  "]
  return $row
}

proc update-raw-file {hash content} {
  # TODO: update as new file with new hash, copy all the things of predecessor!
  set hash [sha2::sha256 $content]
  set now [clock seconds]
  set updated_at [clock format $now -gmt 1 -format "%Y-%m-%dT%H:%M:%SZ"]
  set row [get-file $id]
  lassign $row id name title description type extension tags
  set file [open $path "w"]
  fconfigure $file -translation binary
  puts -nonewline $file $content
  close $file
  db eval "UPDATE files SET updated_at = '$updated_at', hash = '$hash' WHERE id = '$id';"
  return $id
}

proc add-file {name type content} {
  global upload_path
  set hash [sha2::sha256 $content]

  set exist [db eval "SELECT hash FROM files WHERE hash == '$hash'"]
  if {[string trim $exist] != ""} {
    wapp-trim {
      <p>File %html($name) already exists.</p>
    }
    return
  } else {
    set file_path "$upload_path/$hash"
    set extension [split $name .]
    if { [llength $extension ] > 0 } {
      set extension [lindex $extension end]
    }
    set file_path "$file_path.$extension"
    set file [open $file_path "w"]
    fconfigure $file -translation binary
    puts -nonewline $file $content
    close $file
    db eval "INSERT INTO files (hash,name,type,extension) VALUES ('$hash','$name','$type','$extension')"
    return $hash
  }
}

proc add-tag {name file_hash} {
  # check if tag with name already exists:
  set tag_id [db eval {SELECT id FROM tags WHERE name == :name}]
  if {$tag_id == ""} {
    set tag_id [uuid::uuid generate]
    db eval "
      BEGIN TRANSACTION;
      INSERT INTO tags (id,name) VALUES ('$tag_id','$name');
      COMMIT;
    "
  }
  # Insert but ignore if already exists:
  db eval "
    BEGIN TRANSACTION;
    INSERT OR IGNORE INTO files_tags (file_hash,tag_id) VALUES ('$file_hash','$tag_id');
    COMMIT;
  "
  return $tag_id
}

proc header {} {
  wapp-trim {
    <!DOCTYPE html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <meta http-equiv="content-type" content="text/html; charset=UTF-8">
      <link href="%url(/style.css)" rel="stylesheet">
      <link rel="alternate" type="application/rss+xml" title="doomtown cottbus" href="/rss"/>
      <title>doomtown</title>
    </head>
    <body>
      <div class="app">
        <div class="header">
          <img class="logo" src="/header.gif" alt="DOOMTOWN" />
          <header>
            <h1>Lokales Netzwerk Cottbus</h1>
            <nav>
              <ul>
                <li><a href="/">Index</a></li>
                <li><a href="/files">Dateien</a></li>
                <li><a href="/apps">Programme</a></li>
                <li><a href="/tags">Stichwörter</a></li>
                <li><a href="/upload">Upload</a></li>
                <li><a href="/contact">Kontakt</a></li>
              </ul>
            </nav>
          </header>
        </div>
  }
}

proc footer {} {
  wapp-trim {
      <div class="footer">
        <p><a href="/rss" target="rss">RSS</a></p>
        <p class="small"></p>
      </div>
    </div>
    </body>
    </html>
  }
}

proc layout {content} {
  wapp-content-security-policy off
  # {default-src 'self'; img-src 'self' data:}
  header
  wapp-subst {<div class="content"><div class="wrap">}
  eval $content
  wapp-subst {</div></div>}
  footer
}

proc show-text {content} {
  wapp-trim {
    <p>
      <pre>
        %html($content)
      </pre>
    </p>
  }
}

proc show-audio {type path} {
  global baseurl
  wapp-trim {
    <audio controls>
      <source src="%url($baseurl)%url($path)" type="%html($type)">
      Your browser does not support the audio element.
    </audio>
  }
}

proc loadTextFile {path} {
  set file [open $path r]
  set content [read $file]
  close $file
  return $content
}

proc loadBinaryFile {path} {
  set file [open $path r]
  fconfigure $file -translation binary
  set content [read $file]
  close $file
  return $content
}

proc imageAsBase64 {type content} {
  set b64 [binary encode base64 $content]
  wapp-trim {
    <img class="image" src='data:%html($type);base64,%html($b64)'>
  }
}

proc wapp-page-style.css {} {
  wapp-mimetype text/css
  wapp-cache-control max-age=3600
  wapp-unsafe {
    * {
      margin: 0;
      padding: 0;
    }

    body {
      background: #999;
      font-family: monospace, courier;
      font-size: 1em;
    }

    .small {
      font-size: 0.6em;
    }

    input[type=button], input[type=submit], input[type=reset], input[type=reset], button {
      padding: 0.5em 1em;
      background-color: #009966;
      border: 1px solid #666;
      color: white;
      text-decoration: none;
      cursor: pointer;
    }

    input[type=text] {
      line-height: 2em;
      padding-left: 0.2em;
    }

    input[type=submit].red {
      background-color: #f00;
    }

    .app {
      width: 80%;
      background: #fff;
      margin: 0 auto 0 auto;
      border-left: 2px solid black;
      border-right: 2px solid black;
      border-bottom: 2px solid black;
    }

    .header {
      padding: 1em 0 0 0;
    }

    nav ul {
      list-style: none;
      padding: 1em 1em 0 1em;
    }

    nav li {
      display: inline;
      margin-right: 1em;
    }

    .logo {
      display: block;
      margin-left: auto;
      margin-right: auto;
      image-rendering: pixelated;
      width: 60%;
      max-width: 600px;
    }

    .footer {
      padding: 2em 1em 1em 1em;
    }

    h1 {
      font-size: 1.3em;
    }

    @media (max-width: 800px ) {
      body {
        font-size: 1.1em;
      }

      .app {
        width: 100%;
        margin: 0;
        border: 0px;
      }

      .logo {
        width: 80%;
      }
    }

    .header h1 {
      text-align: center;
      margin-top: 1em;
      color: #666;
    }

    .content .wrap {
      padding: 1em 1em 0 1em;
    }

    .content p {
      padding: 1em 0 1em 0;
    }

    .content form {
      padding: 1em 0 1em 0;
    }

    .content ul {
      margin: 1em 0 0 1em;
    }

    .content pre {
      white-space: pre-wrap;
      font-size: 1.2em;
    }

    .content .image {
      width: 50%;
    }
  }
}

proc wapp-page-favicon.ico {} {
  wapp-mimetype image/gif
  wapp-cache-control max-age=3600
  wapp-unsafe [binary decode hex {
    47494638396108000800f10200000000ffffffffff0000000021f90405080002
    002c000000000800080000020c448c718b99ccdc828d2a090a003b
  }]
}

proc wapp-page-header.gif {} {
  wapp-mimetype image/gif
  wapp-cache-control max-age=3600
  wapp-unsafe [binary decode base64 {
    R0lGODlhGAEwAPEAAAAAAP///yZFySZFySH5BAEAAAIALAAAAAAYATAAAAL/hI9p
    we0PI1NI2kfPxXtnIH3iuEBi14BqAKIpFbpWxpKV3JG4o6PlXqNFbMQbZiRbrZKw
    YQs4aRZ/UJ4NSPRRXUjntHcEX5SsndC0xZ2/VWuW+R5r4J/Qtxu+5spLbhOd5qfg
    Fgd1J1jkYaSIl3c3CJg4xlem9udoeBlUaHnIyDaTkKMX+bj44jlD+aQFWcqKeLpJ
    Spfq9RgqmitGaBroC8uzaqaJKvt5DBqLe2tq5+rY2Ov8astBVjtXHSwHPR1Y2aq7
    /TweDQ58kg1efjyrfc696678LX92tIxeHOVtTA8jC75R/rqZs9cOHsGD/zTUiZdw
    nzyIzRQ2lMiwn64e/wORWTQIsOA7dhUx3nh48R6/TQtDZhypUuQalB1Bfpx3sybM
    Ti9nXtIJ1F3KiDF7rsSHdCVRni6b3lxakhXNo1SF7owKlRzWaRT1TdyqNaw4p1se
    BpUp8qpYhGC7GlvrkSRcjWS/zlWbUkVVo2j78v1b10nblk8HDzVs0+THemzvAh2W
    1a0wbOvsXqPENOdeq44hRz0LWHNaMkUDx6A8tvAQz6kVu7bc2ATreJtFh0Y3O7bu
    FLnjwuaNunVp25wlA8eME7Tpu8OGv1YV3LeZ3smdW8/MjrTv29cRN68eeTJyr2qo
    g/euM/zxPom5q6f7VDt6pfLJl4/e/j1ewtnN2/8jDuBzq+EHn4CyEXgeF/7N51dx
    u02w4H/dOUYfdcrFF+GDkyDIoHuVQTfedqeFqOGFBl7GnnH5fZiEeSb+BiGC6Q1I
    ongpHkZhgxgSOCNz3oF4Y4ETKsijUiMG+Z1+LyrpopE+PoliODm+dKSUKgJpZZRD
    llhbf0Wm9WOYNCK55H017rcHj03qeGKJa1Ip5pVVTlQmkWeiueGdSU65nJz1yRmn
    hlhuiaOdZDp54Jl/Xlkno286WCh/MO7Jp2paJuiDf4tGyqmQ+lEqaKCd5nkom5OC
    OuqgTMrYJaGeihqjnrDiSWtNv7SKnauxluphpW2mKSugvhIqS6OSrnqnsaPxKktq
    ltKxOGw0jCLK5WgW4tphn5lyCGW1veLFLKZusmqqktga6uyK9kUr5A/hmmvtl996
    qy2wSH6abYAtcHSucMjeG27A1K6XrrjPRitQv8f+uOmr7D6M7qQ9TmtqOrq+Z7F1
    UxC18awTh7pNxyGngy9cGbfHCW20CMsyyCPzIuFGK7us28nbSfMZzjSnOmu7Oudl
    Dsw7OwwTY9WpIynSJbfM89EocVzs0x7/YbNXHwMNJtELr0tMyi9f3DRFVVeWdc4O
    Xq31wVjMbLZN/n44dq6Qfs311m9XIXTOC9V9M8ltKL022mjTuvTNZPsBrXAFAAA7
  }]
}


setup-db
wapp-start $wapp_args