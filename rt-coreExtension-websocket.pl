#!/usr/bin/env perl
use utf8;
use Mojolicious::Lite;
use Mojolicious::Plugin::Config;
use Mojo::Redis2;
use Mojo::UserAgent;
use Mojo::Message::Request;
use Mojo::Message::Response;
use Mojo::JSON qw(decode_json encode_json);
# use Data::Dumper;

# use MOJO_CONFIG=/path/to/myapp.conf
my $config = plugin Config => {};

my %cbs;
my $redis;
# WS client record
my $clients = {};
my $messageCounter = 0;


# keep-alive for redis-context
# in case redis crashed and/or was restarted we try to 
# reconnect every 2 seconds
$redis = Mojo::Redis2->new;
$redis->on(connection => sub { my ($self, $info) = @_; 
  say "redis connection established";
  $redis->subscribe([$config->{channel}], sub { 
    my ($self, $err, $res) = @_; 
  });
});
Mojo::IOLoop->recurring(2 => sub {
  my $loop = shift;
  $redis->get("foo");
});
$redis->on(error => sub { my ($self, $err) = @_; 
  say "redis error: '$err'. Trying to reconnect every 2 seconds.";
});
$redis->on(message => sub {
  my ($self, $message, $channel) = @_;

  if ($config->{debug}) {
    say "redis received message: '", $message, "' on channel: '", $channel, "'";
  }

  # discard messages for other channels
  if ($channel ne $config->{channel}) {
    say "ignoring message from channel: ", $channel, " ", $config->{channel};
    return;
  }

  # normalize the events by 200ms
  # Q: why is this required?
  # A: ticket updates are monitored by introspecting the sub _Set() function
  #    which can easily span 4 events in a timeframe of 200ms.
  #    this codes converts this into just one event!


  if (defined $cbs{$message}) {
    Mojo::IOLoop->remove($cbs{$message});
  }
  $cbs{$message} = Mojo::IOLoop->timer(0.2 => sub {
    delete $cbs{$message};
    my $id = $message;

    # generate a message like this:
    #   { "ticketUpdate" : { "id" : 234, "sequence": 34 }};
    my $bytes = encode_json {updateTicket => { id => $id, sequence => $messageCounter }};

    say STDERR "normalizer: sending delayed update: ", $bytes;
    for (keys %$clients) {
      $clients->{$_}->send({text => $bytes});
    }
    $messageCounter = $messageCounter + 1;
  });
});


# tries to use the REST interface in order to check if the supplied 
# cookie is valid
sub checkPermission {
  my $self = shift;
  my $req = $self->req;

  if ($config->{debug}) {
    say "\nWe try all client supplied certificates, if one works with REST the client may connect to the WS.";
  }

  foreach (@{$req->cookies}) {
    my $cookie = $_;
    if ($config->{debug}) {
      say " name: ", $_->name, "\n";
      say " value: ", $_->value, "\n";
    }

    if ($config->{debug}) {
      say " --------- UserAgent request --------- ";
    }
    my $ua1 = Mojo::UserAgent->new;
    $ua1         = $ua1->connect_timeout(3);
    my $cookie_jar = $ua1->cookie_jar;
    $ua1            = $ua1->cookie_jar(Mojo::UserAgent::CookieJar->new);
    $ua1->cookie_jar->add(
      Mojo::Cookie::Response->new(
        name   => $cookie->name,
        value  => $cookie->value,
        domain => $config->{targetDomain},
        path   => $config->{targetPath}
      )
    );

    my $result = $ua1->get($config->{targetURL} => {Accept => '*/*'})->res;
    if ($config->{debug}) {
      say "result->body: ", $result->body;
      say "result->code: ", $result->code;
      say " --------- /UserAgent request --------- ";
    }
    # ugly HACK since request tracker's REST 1.0 interface 
    #           returns no JSON and does not use HTTP return codes (qknight)
    my $firstLine = ( split /\n/, $result->body )[0];
    my $returnCodeString = ( split / /, $firstLine )[1];

    if ($returnCodeString == "200") {
      return 1;
    }
  }
  return 0;
}

get '/' => 'index';

# get '/status' => sub {
#   
# 
# }

websocket '/websocket' => sub {
  my $self = shift;
  # SECURITY WS connection is not limited in time as cookie
  # is only checked before WS connection is established
  # once the context is open, it is not checked anymore!

  # 600sec ~ 10min timeout
  $self->inactivity_timeout(600);

  my $id = sprintf "%s", $self->tx;
  $clients->{$id} = $self->tx;

  if (checkPermission($self) != 1) {
    app->log->debug(sprintf 'Client NOT authorized, diconnecting: %s', $self->tx);
    return;
  } else {
    app->log->debug(sprintf 'Client connected: %s', $self->tx);
  }

  # on first connect, send { "sequence" : $sequence } so that
  # clients know if they need to requery/redraw everything after reconnect
  my $bytes = encode_json {updateTicket => { sequence => $messageCounter }};
  $clients->{$id}->send({text => $bytes});

  $self->on(finish => sub {
      app->log->debug('Client disconnected');
      delete $clients->{$id};
  });
};

app->start;

__DATA__
@@ index.html.ep
<html>
  <head>
    <title>WebSocket Client</title>
    <script
      type="text/javascript"
      src="http://ajax.googleapis.com/ajax/libs/jquery/1.4.2/jquery.min.js"
    ></script>
<script>
!function(a,b){"function"==typeof define&&define.amd?define([],b):"undefined"!=typeof module&&module.exports?module.exports=b():a.ReconnectingWebSocket=b()}(this,function(){function a(b,c,d){function l(a,b){var c=document.createEvent("CustomEvent");return c.initCustomEvent(a,!1,!1,b),c}var e={debug:!1,automaticOpen:!0,reconnectInterval:1e3,maxReconnectInterval:3e4,reconnectDecay:1.5,timeoutInterval:2e3};d||(d={});for(var f in e)this[f]="undefined"!=typeof d[f]?d[f]:e[f];this.url=b,this.reconnectAttempts=0,this.readyState=WebSocket.CONNECTING,this.protocol=null;var h,g=this,i=!1,j=!1,k=document.createElement("div");k.addEventListener("open",function(a){g.onopen(a)}),k.addEventListener("close",function(a){g.onclose(a)}),k.addEventListener("connecting",function(a){g.onconnecting(a)}),k.addEventListener("message",function(a){g.onmessage(a)}),k.addEventListener("error",function(a){g.onerror(a)}),this.addEventListener=k.addEventListener.bind(k),this.removeEventListener=k.removeEventListener.bind(k),this.dispatchEvent=k.dispatchEvent.bind(k),this.open=function(b){h=new WebSocket(g.url,c||[]),b||k.dispatchEvent(l("connecting")),(g.debug||a.debugAll)&&console.debug("ReconnectingWebSocket","attempt-connect",g.url);var d=h,e=setTimeout(function(){(g.debug||a.debugAll)&&console.debug("ReconnectingWebSocket","connection-timeout",g.url),j=!0,d.close(),j=!1},g.timeoutInterval);h.onopen=function(){clearTimeout(e),(g.debug||a.debugAll)&&console.debug("ReconnectingWebSocket","onopen",g.url),g.protocol=h.protocol,g.readyState=WebSocket.OPEN,g.reconnectAttempts=0;var d=l("open");d.isReconnect=b,b=!1,k.dispatchEvent(d)},h.onclose=function(c){if(clearTimeout(e),h=null,i)g.readyState=WebSocket.CLOSED,k.dispatchEvent(l("close"));else{g.readyState=WebSocket.CONNECTING;var d=l("connecting");d.code=c.code,d.reason=c.reason,d.wasClean=c.wasClean,k.dispatchEvent(d),b||j||((g.debug||a.debugAll)&&console.debug("ReconnectingWebSocket","onclose",g.url),k.dispatchEvent(l("close")));var e=g.reconnectInterval*Math.pow(g.reconnectDecay,g.reconnectAttempts);setTimeout(function(){g.reconnectAttempts++,g.open(!0)},e>g.maxReconnectInterval?g.maxReconnectInterval:e)}},h.onmessage=function(b){(g.debug||a.debugAll)&&console.debug("ReconnectingWebSocket","onmessage",g.url,b.data);var c=l("message");c.data=b.data,k.dispatchEvent(c)},h.onerror=function(b){(g.debug||a.debugAll)&&console.debug("ReconnectingWebSocket","onerror",g.url,b),k.dispatchEvent(l("error"))}},1==this.automaticOpen&&this.open(!1),this.send=function(b){if(h)return(g.debug||a.debugAll)&&console.debug("ReconnectingWebSocket","send",g.url,b),h.send(b);throw"INVALID_STATE_ERR : Pausing to reconnect websocket"},this.close=function(a,b){"undefined"==typeof a&&(a=1e3),i=!0,h&&h.close(a,b)},this.refresh=function(){h&&h.close()}}return a.prototype.onopen=function(){},a.prototype.onclose=function(){},a.prototype.onconnecting=function(){},a.prototype.onmessage=function(){},a.prototype.onerror=function(){},a.debugAll=!1,a.CONNECTING=WebSocket.CONNECTING,a.OPEN=WebSocket.OPEN,a.CLOSING=WebSocket.CLOSING,a.CLOSED=WebSocket.CLOSED,a});
</script>
    <script type="text/javascript">
      $(function () {
        var log = function (text) {
          $('#log').val( $('#log').val() + text + "\n");
        };
    
        var ws = new ReconnectingWebSocket(window.location.href.replace('http', 'ws') + "websocket");

        ws.onopen = function () {
          log('Connection opened');
          setInterval(function() {
            ws.send("Keep alive from client"  );
          }, 200000 );
        };
    
        ws.onmessage = function (msg) {
          var res = JSON.parse(msg.data);
          log(res.text);
        };
        ws.onclose = function (msg) {
          log('Connection closed'); 
        };
      });
    </script>
    <style type="text/css">
      textarea {
          width: 40em;
          height: 70%;
      }
    </style>
  </head>
<body>

<h1>Mojolicious + WebSocket</h1>
<p>If you logged into RT already, and then reload this page you will see that the WebSocket was able to connect and for every ticket update in RT you will receive the INT ID here. This can be used for debugging.</p>
<textarea id="log" readonly></textarea>

</body>
</html>
