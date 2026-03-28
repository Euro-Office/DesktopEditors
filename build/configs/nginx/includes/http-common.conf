upstream docservice {
  server localhost:8000 max_fails=0 fail_timeout=0s;
}

upstream adminpanel {  
  server localhost:9000 max_fails=0 fail_timeout=0s;
}

upstream example {  
  server localhost:3000;
}

map $http_host $this_host {
    "" $host;
    default $http_host;
}

map $http_cloudfront_forwarded_proto:$http_x_forwarded_proto $the_scheme {
     default $scheme;
     "~^https?:.*" $http_cloudfront_forwarded_proto;
     "~^:https?$" $http_x_forwarded_proto;
}

map $http_x_forwarded_host $the_host {
    ~^([^,]+)  $1;
    default $http_x_forwarded_host;
    "" $this_host;
}

map $http_upgrade $proxy_connection {
  websocket upgrade;
  default close;
}

map $http_x_forwarded_prefix $the_prefix {
    default $http_x_forwarded_prefix;
}

proxy_set_header Host $http_host;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection $proxy_connection;
proxy_set_header X-Forwarded-Host $the_host;
proxy_set_header X-Forwarded-Proto $the_scheme;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
