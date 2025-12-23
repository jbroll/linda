#!/usr/bin/env tclsh

# Linda HTTP Service - REST API wrapper for Linda tuple space
# Usage: ./linda-http.tcl [-server addr:port] [-local port] [-scgi port]

package require Tcl 8.6

# Load required modules
source wapp.tcl
source wapp-routes.tcl
source linda.tcl

# Initialize Linda
package require linda

# Set CORS headers for cross-origin requests
proc wapp-before-dispatch-hook {} {
    wapp-reply-extra "Access-Control-Allow-Origin" "*"
    wapp-reply-extra "Access-Control-Allow-Methods" "GET, POST, DELETE, OPTIONS"
    wapp-reply-extra "Access-Control-Allow-Headers" "Content-Type, X-TTL, X-Mode"
    
    # Handle preflight OPTIONS requests
    if {[wapp-param REQUEST_METHOD] eq "OPTIONS"} {
        wapp-reply-code "200 OK"
        wapp ""
        return
    }
}

# Helper to set JSON content type
proc json-response {} {
    wapp-mimetype "application/json; charset=utf-8"
}

# Helper to return JSON error
proc json-error {code message} {
    wapp-reply-code $code
    json-response
    wapp [subst {{"error": "[wappInt-enc-string $message]"}}]
}

# Helper to return JSON success
proc json-success {data} {
    wapp-reply-code "200 OK"
    json-response
    wapp $data
}

proc get-body {} {
    if {[wapp-param-exists CONTENT]} {
        return [wapp-param CONTENT]
    }
    return ""
}

proc get-ttl {} {
    set ttl 0
    
    if {[wapp-param-exists ttl]} {
        set ttl [wapp-param ttl]
    }
    
    if {![string is integer -strict $ttl] || $ttl < 0} {
        error "Invalid TTL value: $ttl"
    }
    
    return $ttl
}

proc get-mode {} {
    set mode ""
    
    if {[wapp-param-exists mode]} {
        set mode [wapp-param mode]
    }
    
    if {$mode ne "" && $mode ni {seq rep}} {
        error "Invalid mode: $mode. Must be 'seq' or 'rep'"
    }
    
    return $mode
}

proc get-timeout {} {
    set timeout ""
    
    if {[wapp-param-exists timeout]} {
        set timeout [wapp-param timeout]
        if {$timeout eq "once"} {
            return "once"
        } elseif {[string is integer -strict $timeout] && $timeout >= 0} {
            return $timeout
        } else {
            error "Invalid timeout: $timeout. Must be 'once' or non-negative integer"
        }
    }
    
    return $timeout
}

#
# API Routes
#

# POST /tuples/{name} - Create/store a tuple
# Body: tuple data
# Params: ttl=N, mode=seq|rep
wapp-route POST /tuples/name {
    try {
        set data [get-body]
        set ttl [get-ttl]
        set mode [get-mode]
        
        if {$mode eq ""} {
            linda::out $name $data $ttl
        } else {
            linda::out $name $data $ttl $mode
        }
        
        json-success [subst {{"success": true, "message": "Tuple stored", "name": "[wappInt-enc-string $name]"}}]
        
    } trap {TCL LOOKUP} {msg opts} {
        json-error "400 Bad Request" $msg
    } on error {msg} {
        json-error "400 Bad Request" $msg
    }
}

# GET /tuples/{name} - Read tuple without consuming (rd operation)
# Params: timeout=once|N
wapp-route GET /tuples/name {
    try {
        set timeout [get-timeout]
        
        if {$timeout eq ""} {
            set data [linda::rd $name]
        } else {
            set data [linda::rd $name $timeout]
        }
        
        json-response
        wapp [subst {{"success": true, "name": "[wappInt-enc-string $name]", "data": "[wappInt-enc-string $data]"}}]
        
    } trap {TCL LOOKUP} {msg opts} {
        if {[string match "*No tuple matching*" $msg]} {
            json-error "404 Not Found" "No tuple matching pattern: $name"
        } elseif {[string match "*Timeout*" $msg]} {
            json-error "408 Request Timeout" "Timeout waiting for tuple: $name"
        } else {
            json-error "400 Bad Request" $msg
        }
    } on error {msg} {
        json-error "500 Internal Server Error" $msg
    }
}

# DELETE /tuples/{name} - Consume tuple (inp operation)  
# Params: timeout=once|N
wapp-route DELETE /tuples/name {
    try {
        set timeout [get-timeout]
        
        if {$timeout eq ""} {
            set data [linda::inp $name]
        } else {
            set data [linda::inp $name $timeout]
        }
        
        json-response
        wapp [subst {{"success": true, "name": "[wappInt-enc-string $name]", "data": "[wappInt-enc-string $data]"}}]
        
    } trap {TCL LOOKUP} {msg opts} {
        if {[string match "*No tuple matching*" $msg]} {
            json-error "404 Not Found" "No tuple matching pattern: $name"
        } elseif {[string match "*Timeout*" $msg]} {
            json-error "408 Request Timeout" "Timeout waiting for tuple: $name"
        } else {
            json-error "400 Bad Request" $msg
        }
    } on error {msg} {
        json-error "500 Internal Server Error" $msg
    }
}

# GET /tuples - List all tuples (ls operation)
# Params: pattern=*
wapp-route GET /tuples {
    try {
        set pattern "*"
        if {[wapp-param-exists pattern]} {
            set pattern [wapp-param pattern]
        }
        
        set listing [linda::ls $pattern]
        
        json-response
        set json_items {}
        foreach item $listing {
            set parts [split $item " "]
            set count [lindex $parts 0]
            set name [lindex $parts 1]
            lappend json_items [subst {{"name": "[wappInt-enc-string $name]", "count": $count}}]
        }
        wapp [subst {{"success": true, "tuples": [[join $json_items ", "]]}}]
        
    } on error {msg} {
        json-error "500 Internal Server Error" $msg
    }
}

# DELETE /tuples - Clear all tuples
wapp-route DELETE /tuples {
    try {
        linda::clear
        json-success {{"success": true, "message": "All tuples cleared"}}
    } on error {msg} {
        json-error "500 Internal Server Error" $msg
    }
}

# Health check endpoint
wapp-route GET /health {
    json-success {{"status": "healthy", "service": "linda-http"}}
}

# API documentation endpoint
wapp-route GET /api {
    wapp-mimetype "text/html; charset=utf-8"
    wapp-trim {
        <!DOCTYPE html>
        <html>
        <head>
            <title>Linda HTTP Service API</title>
            <style>
                body { font-family: Arial, sans-serif; margin: 40px; }
                .endpoint { margin: 20px 0; padding: 15px; border: 1px solid #ddd; }
                .method { font-weight: bold; color: #0066cc; }
                code { background: #f4f4f4; padding: 2px 4px; }
                pre { background: #f4f4f4; padding: 10px; }
            </style>
        </head>
        <body>
            <h1>Linda HTTP Service API</h1>
            
            <div class="endpoint">
                <div class="method">POST /tuples/{name}</div>
                <p>Store a tuple with the given name.</p>
                <p><strong>Body:</strong> Tuple data (text or binary)</p>
                <p><strong>Headers/Params:</strong></p>
                <ul>
                    <li><code>X-TTL</code> or <code>ttl=N</code> - Time to live in seconds</li>
                    <li><code>X-Mode</code> or <code>mode=seq|rep</code> - Storage mode (seq=FIFO, rep=replacement)</li>
                </ul>
            </div>
            
            <div class="endpoint">
                <div class="method">GET /tuples/{name}</div>
                <p>Read a tuple without consuming it (peek).</p>
                <p><strong>Params:</strong></p>
                <ul>
                    <li><code>timeout=once|N</code> - Non-blocking (once) or timeout in seconds</li>
                </ul>
            </div>
            
            <div class="endpoint">
                <div class="method">DELETE /tuples/{name}</div>
                <p>Consume (read and remove) a tuple.</p>
                <p><strong>Params:</strong></p>
                <ul>
                    <li><code>timeout=once|N</code> - Non-blocking (once) or timeout in seconds</li>
                </ul>
            </div>
            
            <div class="endpoint">
                <div class="method">GET /tuples</div>
                <p>List all tuples with counts.</p>
                <p><strong>Params:</strong></p>
                <ul>
                    <li><code>pattern=*</code> - Pattern to match tuple names (supports wildcards)</li>
                </ul>
            </div>
            
            <div class="endpoint">
                <div class="method">DELETE /tuples</div>
                <p>Clear all tuples from the tuple space.</p>
            </div>
            
            <h2>Examples</h2>
            <pre>
# Store a tuple with 30 second TTL
curl -X POST "http://localhost:8080/tuples/job1?ttl=30" -d "process this data"

# Store with FIFO semantics
curl -X POST "http://localhost:8080/tuples/queue?mode=seq" -d "first item"

# Read without consuming
curl "http://localhost:8080/tuples/job1"

# Non-blocking read
curl "http://localhost:8080/tuples/job1?timeout=once"

# Consume tuple
curl -X DELETE "http://localhost:8080/tuples/job1"

# List all tuples
curl "http://localhost:8080/tuples"

# List tuples matching pattern
curl "http://localhost:8080/tuples?pattern=job*"

# Clear all tuples
curl -X DELETE "http://localhost:8080/tuples"
            </pre>
        </body>
        </html>
    }
}

# Default page - redirect to API docs
proc wapp-default {} {
    set path [wapp-param PATH_INFO]
    if {$path eq "/" || $path eq ""} {
        wapp-redirect "/api"
    } else {
        wapp-reply-code "404 Not Found"
        json-error "404 Not Found" "Endpoint not found: $path"
    }
}

# Start the server
if {[info exists argv]} {
    # Default to local server on port 8080
    if {[llength $argv] == 0} {
        set argv [list -local 8080]
    }
    wapp-start $argv
} else {
    # For interactive testing
    wapp-start [list -local 8080]
}
