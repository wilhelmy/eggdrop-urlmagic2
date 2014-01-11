#! tclsh
# Copyright (c) 2011      by Steve "rojo" Church
#           (c) 2013-2014 by Moritz "ente" Wilhelmy
#
# See README and LICENSE for more information.

# User variables, allow changing the config file that will be loaded by urlmagic
namespace eval ::urlmagic {

# Specifies the config file which contains all other settings for urlmagic.
set settings(config-file) "conf/urlmagic.tcl"

}

################################################################################
#                        End of user variables                                 #
################################################################################



namespace eval ::urlmagic {

proc warn {text} {
	set ns [string trim [uplevel 1 namespace current] :]
	putlog "\002(Warning)\002 $ns: $text"
}

if {! [file exists $urlmagic::settings(config-file)]} {
	warn "Configuration file $urlmagic::settings(config-file) does not exist. Bailing out."
	warn "Make sure to read the README"
	return 1
}

variable VERSION 1.1+hg
variable cookies
variable ns [namespace current]
variable ignores ;# temporary ignores
set settings(base-path) [file dirname [info script]]

variable title ;# contains process_title's things, also used for string building by hooks

  
if {$settings(htmltitle) != "dumb"} {
	load tcl/urlmagic/htmltitle_$settings(htmltitle)/htmltitle.so
} else {
	# "dumb" htmltitle implementation
	proc htmltitle {data} {
		set data [string map {\r "" \n ""} $data]
		if {[regexp -nocase {<\s*?title\s*?>\s*?(.*?)\s*<\s*/title\s*>} $data - title]} {
			return [string map {&#x202a; "" &#x202c; "" &rlm; ""} [string trim $title]]; # "for YouTube", says rojo
		}
	}
}

proc unignore {nick uhost hand chan msg} {
	# HACK: just unignore someone leaving *any* channel
	variable ignores
	catch { unset ignores($uhost) }
}

proc ignore {uhost chan} {
	variable ignores; variable settings

	set now [unixtime]

	if {$settings(seconds-between-user) && [info exists ignores($uhost)]
	&& $ignores($uhost) > $now - $settings(seconds-between-user) } then {
		incr ignores($uhost) $settings(url-flooding-penalty)
		return 1
	}

	if {$settings(seconds-between-channel) && [info exists ignores($chan)]
	&& $ignores($chan) > $now - $settings(seconds-between-channel) } then {
		# introducing a penalty for a noisy channel doesn't seem particularly useful
		return 1
	}

	set ignores($uhost) $now
	set ignores($chan) $now

	return 0
}

proc find_urls {nick uhost hand chan txt} {

	variable settings; variable twitter; variable skip_sqlite3; variable ns

	if {[matchattr $hand $settings(ignore-flags)] || ![channel get $chan $settings(udef-flag)]} { return }

	if {[regexp -nocase $settings(url-regex) $txt url] && [string length $url] > 7} {

		if {[ignore $uhost $chan]} return

		# FIXME should this be just // to account for URLs like //imgur.com/ where the protocol is implicit?
		# In any case, wouldn't work as expected. rewrite.
		set url_complete [string match *://* $url]
		if {!$url_complete} { set url "http://$url" }

		variable title
		array set title [list nick $nick uhost $uhost hand $hand chan $chan text $txt]
		# $title(url, content-length, tinyurl [where $url length > max], title, error [boolean])
		process_title $url

		# list used for string building
		set title(output) [list "<$nick>" "\002$title(title)\002"]

		# Pre-String hook: Called before the string builders are invoked.
		hook::call urlmagic <Pre-String> 

		# String hook: Called for all string builders
		hook::call urlmagic <String>

		puthelp "PRIVMSG $chan :[join $title(output)]"
		hook::call urlmagic <Post-String>
	}
}

# TODO: rewrite cookie code.
# use cron bind to expire both old cookies and ignores
proc update_cookies {tok} {
	variable cookies; variable settings; variable ns

	upvar #0 $tok state
	set domain [lindex [split $state(url) /] 2]
	if {![info exists cookies($domain)]} { set cookies($domain) [list] }
	foreach {name value} $state(meta) {

		if {[string equal -nocase $name "Set-Cookie"]} {

			if {[regexp -nocase {expires=([^;]+)} $value - expires]} {

				if {[catch {expr {([clock scan $expires -gmt 1] - [clock seconds]) / 60}} expires] || $expires < 1 } {
					set expires 15
				} elseif {$expires > $settings(max-cookie-age)} {
					set expires $settings(max-cookie-age)
				}
			} { set expires $settings(max-cookie-age) }

			set value [lindex [split $value \;] 0]
			set cookie_name [lindex [split $value =] 0]

			set expire_command [list ${ns}::expire_cookie $domain $cookie_name]

			if {[set pos [lsearch -glob $cookies($domain) ${cookie_name}=*]] > -1} {
				set cookies($domain) [lreplace $cookies($domain) $pos $pos $value]
				foreach t [timers] {
					if {[lindex $t 1] == $expire_command} { killtimer [lindex $t 2] }
				}
			} else {
				lappend cookies($domain) $value
			}

			timer $expires $expire_command
		}
	}
}

proc expire_cookie {domain cookie_name} {
	variable cookies
	if {![info exists cookies($domain)]} { return }
	if {[set pos [lsearch -glob $cookies($domain) ${cookie_name}=*]] > -1} {
		set cookies($domain) [lreplace $cookies($domain) $pos $pos]
	}
	if {![llength $cookies($domain)]} { unset cookies($domain) }
}

# Lookup table for non-printable characters which need to be URL-encoded
variable enc [list { } +]
for {set i 0} {$i < 256} {incr i} {
	if {$i > 32 && $i < 127} { continue }
	lappend enc [format %c $i] %[format %02x $i]
}
unset i

proc pct_encode_extended {what} {
	variable enc
	return [string map $enc $what]
}

# Interpret an URL fragment relative to a complete URL
proc relative {full partial} {
	if {[string match -nocase http* $partial]} { return $partial }
	set base [join [lrange [split $full /] 0 2] /]
	if {[string equal [string range $partial 0 0] /]} {
		return "${base}${partial}"
	} else {
		return "[join [lreplace [split $full /] end end] /]/$partial"
	}
}

# Extract the charset from a charset=... directive as found in HTTP headers and HTML
# Partially stolen from the http library, but somewhat modified to work with HTML
proc extract_charset {content_type charset} {
	if {[regexp -nocase {charset\s*=\s*\"((?:[^""]|\\\")*)\"} $content_type -> cs]} {
		set charset [string map {{\"} \"} $cs]
	} else {
		regexp -nocase {charset\s*=\s*(\S+?);?} $content_type -> charset
	}
	regsub -all -nocase {[^a-z0-9_-]} $charset "" charset
	dccbroadcast "Charset is $charset"
	return $charset
}

# Fix the charset of an HTTP charset according to
#  * <meta charset> / <meta http-equiv="content-type"> if available
#  * HTTP header
# See http://www.edition-w3.de/TR/2000/REC-xml-20001006/#sec-guessing
proc fix_charset {data charset s_type} {
	# First, Check the data for a BOM
	if {[binary scan $data cucucucu b1 b2 b3 b4] < 4} return

	set stripbytes 0

	# TODO is UCS-4 supported at all?
	# FIXME BOM stripping is currently broken. Decoding of UTF-16BE will
	# fail, decoded UTF-16LE will contain the BOM which will confuse the
	# title parser. I have no idea how to strip bytes from binary Tcl
	# strings. Contact me if you do.
	if {$b1 == 255 && $b2 == 254 || $b1 == 254 && $b2 == 255} {
		set charset "unicode"
		set stripbytes 2
	} elseif {$b1 == 239 && $b2 == 187 && $b3 == 191} {
		set charset "utf-8"
		set stripbytes 3
	} else {

	# Next, try the content type. HTML content may override this.
	set charset [extract_charset $s_type $charset]

	# Next, try the header meta tags, which may override the charset sent
	# via HTTP headers
	# FIXME: this implementation is ugly. Use gumbo for this and parse twice?
	set charset [extract_charset $data $charset]
	}

	set charset [http::CharsetToEncoding $charset]
	dccbroadcast "Charset is $charset"

	if {$charset == "binary"} {return ""}
	set data [encoding convertfrom $charset $data]
	return $data
}

# "if a then a else b"
proc any {a b} {
	return [expr {$a != "" ? $a : $b}]
}

# Progress handler which aborts the download if it turns out to be too large
proc progresshandler {tok total current} {
	variable settings
	if {$current >= $settings(max-download)} {
		::http::reset $tok toobig
	}
}

proc fetch {url {post ""} {headers ""} {iterations 0} {validate 1}} {
	# follows redirects, sets cookies and allows post data
	# sets settings(content-length) if provided by server; 0 otherwise
	# sets settings(url) for redirection tracking
	# sets settings(content-type) so calling proc knows whether to parse data
	# returns data if content-type=text/html; returns content-type otherwise
	variable settings; variable cookies; variable ns
	
	if {[string length $post]} { set validate 0 }

	set url [pct_encode_extended $url]
	set settings(url) $url
	set settings(error) ""

	if {![string length $headers]} {
		set headers [list Referer $url]
		set domain [lindex [split $url /] 2]
		if {[info exists cookies($domain)] && [llength $cookies($domain)]} {
			lappend headers Cookie [join $cookies($domain) {; }]
		}
	}

	# -binary true  is essential here because the page charset sometimes
	# does not match the HTTP header charset, sometimes isn't present at
	# all, then the encoding would be forced to ISO-8859-1 by default and
	# unicode would be broken afterwards.
	set command [list ::http::geturl $url             \
	                  -timeout $settings(timeout)     \
	                  -validate $validate             \
	                  -binary true                    \
	                  -progress ${ns}::progresshandler]

	if {[string length $post]} {
		lappend command -query $post
	}

	if {[string length $headers]} {
		lappend command -headers $headers
	}

	set data ""

	if {[catch $command http]} {
		if {[catch {set settings(error) "Error [::http::ncode $http]: [::http::error $http]"}]} {
			set data "Error: Connection timed out."
		}
		::http::cleanup $http
		return $data
	} else {
		update_cookies $http
		set data [::http::data $http]
	}
	
	upvar #0 $http state
	set data [fix_charset $data $state(charset) $state(type)]
	foreach {name val} $state(meta) { set meta([string tolower $name]) $val }

	# $state(status) == "toobig" in case the file wasn't downloaded completely because it was too big

	::http::cleanup $http

	if {[info exists meta(location)]} {
		set meta(redirect) $meta(location)
	}

	if {[info exists meta(redirect)]} {

		set meta(redirect) [relative $url $meta(redirect)]

		if {[incr iterations] < 10} {
			return [fetch $meta(redirect) "" $headers $iterations $validate]
		} else {
			set settings(error) "Error: too many redirections"
			return ""
		}
	}

	if {[info exists meta(content-length)]} {
		set settings(content-length) [any $meta(content-length) 0]
	}
	if {[info exists meta(content-type)]} {
		set settings(content-type) [any [lindex [split $meta(content-type) ";"] 0] "unknown"]
	}
	if {[string match -nocase $settings(content-type) "text/html"]\
	    || [string match -nocase $settings(content-type) "application/xhtml+xml"]} {
		if {$validate} {
			# It was a HEAD request, redo the request with GET
			return [fetch $url "" $headers [incr iterations] 0]
		} else {
			return $data
		}
	} else {
		return "Content type: $settings(content-type)"
	}
}

#catch {source $settings(base-path)/$settings(tinyurl-service)}

proc process_title {url} {
#	returns $ret(url, content-length, tinyurl [where $url length > max], title)
	variable settings
	variable title

	# nuke our part of the array
	set title(data)           [fetch $url "" $settings(default-headers)]
	set title(url)            $url
	set title(expanded-url)   $settings(url)
	set title(error)          [expr {[string length $settings(error)] > 0}]
	set title(content-length) $settings(content-length)
	set title(content-type)   $settings(content-type)

	regsub -all {\s+} [string trim [htmltitle $title(data)]] { } title(title)
	if {$title(title) == ""} {
		if {[string length $settings(error)] > 0} {
			set ret(title) $settings(error)
		} else {
			set ret(title) "Content type: $settings(content-type)"
		}
	}

}

namespace eval plugins {
	set settings(base-path) "$urlmagic::settings(base-path)/plugins"
	set ns [namespace current]

	if {![info exists loaded_plugins]} {
		variable loaded_plugins {}
	}

	proc load {args} {
		variable settings
		variable loaded_plugins
		foreach plugin $args {
			if {$plugin in $loaded_plugins} {
				warn "Can't load plugin, it is already loaded. Use reload to reload"
				return
			}
			if {
				[catch { source "$settings(base-path)/${plugin}.tcl" } err]
			} then {
				warn "Unable to load plugin $plugin: $err"
				return 0
			}
			if {![info exists ::urlmagic::plugins::${plugin}::settings] &&
			   ![info exists ::urlmagic::plugins::${plugin}::no_settings]} then {
				warn "$plugin plugin has settings. Please add them to your configuration file first."
				return 0
			}
			urlmagic::plugins::${plugin}::init_plugin
			lappend loaded_plugins $plugin
			putlog "urlmagic: loaded plugin ${plugin} [set ${plugin}::VERSION]"
			return 1
		}
	}

	proc unload {args} {
		variable loaded_plugins
		variable ns
		foreach plugin $args {
			if {"[namespace current]::$plugin" ni [namespace children]} {
				warn "Can't unload plugin $plugin, it does not appear to be loaded"
				return 0
			}
			urlmagic::plugins::${plugin}::deinit_plugin
			set loaded_plugins [lsearch -inline -not -all $loaded_plugins $plugin]
			set v [set ${plugin}::VERSION]
			namespace delete ::urlmagic::plugins::${plugin}
			putlog "urlmagic: unloaded plugin ${plugin} $v"
			return 1
		}
	}
	proc unload_all {} {
		variable loaded_plugins
		foreach plugin $loaded_plugins {
			unload $plugin
		}
	}

	proc reload {args} {
		foreach plugin $args {
			unload $plugin
			load $plugin
		}
	}

} ;# end namespace "plugins"

plugins::unload_all
source $settings(config-file) ;# read it before initializing everything

# Initialise eggdrop stuff
setudef flag $settings(udef-flag)
bind part - * ${ns}::unignore
bind sign - * ${ns}::unignore
# TODO: cron-bind that automatically deletes stale ignores
bind pubm - * ${ns}::find_urls

# Initialise https
::http::register https 443 ::tls::socket
::http::config -useragent $settings(user-agent)

putlog "urlmagic.tcl $VERSION loaded."

plugins::load {*}$settings(plugins)

}; # end namespace
