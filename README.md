# rt-coreExtension-websocket

this coreExtension is not a normal rt-extension as it extends request tracker 4.2.12+ with websockets by using mojolicious lite.

![A screenshot featuring the Kanban view with WebSocket status](https://raw.githubusercontent.com/nixcloud/rt-coreExtension-websocket/master/internals-and-setup.png)

it is intended that this mojo based webserver is run behind a reverse proxy which mapps '/websocket' into RT's '/'. 

you probably want to use this along with:

* <https://github.com/nixcloud/rt-extension-kanban>

# authentication 

the implementation is this:

1. a client logges into RT
2. inside RT a `mason template like Kanban` might use websockets
3. the ws open call will go to wss://whatever.com/websocket
4. the reverse proxy will map /websocket to the mojo lite webserver
5. but since the client provided his cookies to /websocket also we can use these to check if there is a session already
6. if so we let the browser establish a WS, else we reject 

SECURITY: once a WS context is established, it will last until the client disconnects. session is only checked on connection establishment.

# starting the webserver
## production mode

start the daemon:

    MOJO_CONFIG=/path/to/rt-coreExtension-websocket.conf perl rt-coreExtension-websocket.pl daemon -m production -l http://*:5000
  
## debugging mode

start the daemon:

    MOJO_CONFIG=/path/to/rt-coreExtension-websocket.conf perl rt-coreExtension-websocket.pl daemon  -l http://*:5000
  
SECURITY: without `-m production` it a stacktrace will be printed to the client!

# testing the daemon

    redis-cli PUBLISH rt-ticket-activity "hello world";


# authors

* joachim schiele <js@lastlog.de>
* paul seitz <paul.m.seitz@gmail.com>
