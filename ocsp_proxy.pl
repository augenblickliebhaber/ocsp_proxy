#!/usr/bin/perl
#
# fork from ocsp_proxy
# from author, (c) Philippe Kueck <projects at unixadm dot org>

use strict;
use warnings;

use Math::BigInt;

use HTTP::Daemon;
use HTTP::Status;
use HTTP::Response;
use LWP;

use Redis;

use Convert::ASN1;

use Getopt::Long;
use Pod::Usage;

use POSIX;

use threads;
use Thread::Queue;

select(STDERR); $|++;
select(STDOUT); $|++;

my $config = {
    'host' => '127.0.0.1',
    'port' => 8888,
    'redis_sock' => '/run/redis/redis-server.sock',
    'rprefix' => 'ocspxy_'
};

my $asn_common = q<
Name ::= CHOICE { rdnSequence RDNSequence }
    RDNSequence ::= SEQUENCE OF RelativeDistinguishedName
        RelativeDistinguishedName ::= SET OF AttributeTypeAndValue
            AttributeTypeAndValue ::= SEQUENCE {
                type AttributeType,
                value AttributeValue
            }
                AttributeType ::= OBJECT IDENTIFIER
                AttributeValue ::= ANY

Version ::= ENUMERATED {
    v1 (0),
    v2 (1),
    v3 (2)
}

Validity ::= SEQUENCE {
    notBefore Time,
    notAfter  Time
}

    Time ::= CHOICE {
        utcTime     UTCTime,
        generalTime GeneralizedTime
    }

SubjectPublicKeyInfo ::= SEQUENCE {
    algorithm        AlgorithmIdentifier,
    subjectPublicKey BIT STRING
}

UniqueIdentifier ::= BIT STRING

CertID ::= SEQUENCE {
    hashAlgorithm  AlgorithmIdentifier,
    issuerNameHash OCTET STRING,
    issuerKeyHash  OCTET STRING,
    serialNumber   CertificateSerialNumber
}

AlgorithmIdentifier ::= SEQUENCE {
    algorithm  OBJECT IDENTIFIER,
    parameters ANY DEFINED BY algorithm OPTIONAL
}

CertificateSerialNumber ::= INTEGER

Extensions ::= SEQUENCE OF Extension

    Extension ::= SEQUENCE {
       extnID    OBJECT IDENTIFIER,
       critical  BOOLEAN OPTIONAL,
       extnValue OCTET STRING
    }

  OCSPRequest ::= SEQUENCE {
    tbsRequest TBSRequest
  --  optionalSignature [0] EXPLICIT ANY OPTIONAL
  }
  TBSRequest ::= SEQUENCE {
    version [0] EXPLICIT Version OPTIONAL,
    requestList SEQUENCE OF Request,
    requestExtensions [2] EXPLICIT Extensions OPTIONAL
  }
  Request ::= SEQUENCE {
    reqCert CertID,
    singleRequestExtensions [0] EXPLICIT Extensions OPTIONAL
  }
  
OCSPResponse ::= SEQUENCE {
    responseStatus     OCSPResponseStatus,
    responseBytes  [0] EXPLICIT ResponseBytes OPTIONAL
}

    OCSPResponseStatus ::= ENUMERATED {
        successful       (0),
        malformedRequest (1),
        internalError    (2),
        tryLater         (3),
        sigRequired      (5),
        unauthorized     (6)
    }

    ResponseBytes ::= SEQUENCE {
        responseType OBJECT IDENTIFIER,
        response     OCTET STRING
    }

BasicOCSPResponse ::= SEQUENCE {
    tbsResponseData        ResponseData,
    signatureAlgorithm     AlgorithmIdentifier,
    signature              BIT STRING,
    certs                  ANY OPTIONAL
}

    ResponseData ::= SEQUENCE {
        version            [0] EXPLICIT Version OPTIONAL,
        responderID            ResponderID,
        producedAt             GeneralizedTime,
        responses              SEQUENCE OF SingleResponse,
        responseExtensions [1] EXPLICIT Extensions OPTIONAL
    }

        ResponderID ::= CHOICE {
            byName [1] Name,
            byKey  [2] KeyHash
        }

            KeyHash ::= CHOICE { keyHash KeyHashString }
            KeyHashString ::= OCTET STRING

        SingleResponse ::= SEQUENCE {
            certID               CertID,
            certStatus           CertStatus,
            thisUpdate           GeneralizedTime,
            nextUpdate       [0] EXPLICIT GeneralizedTime OPTIONAL,
            singleExtensions [1] EXPLICIT Extensions OPTIONAL
        }

            CertStatus ::= CHOICE {
                good    [0] IMPLICIT NULL,
                revoked [1] IMPLICIT RevokedInfo,
                unknown [2] IMPLICIT UnknownInfo
            }

            RevokedInfo ::= SEQUENCE {
                revocationTime       GeneralizedTime,
                revocationReason [0] EXPLICIT CRLReason OPTIONAL
            }

                CRLReason ::= ENUMERATED {
                    unspecified           (0),
                    keyCompromise         (1),
                    cACompromise          (2),
                    affiliationChanged    (3),
                    superseded            (4),
                    cessationOfOperation  (5),
                    certificateHold       (6),
                    removeFromCRL         (8),
                    privilegeWithdrawn    (9),
                    aACompromise         (10)
                }

            UnknownInfo ::= NULL


>;

### asn.1 decoder/encoder ###
my $asn = new Convert::ASN1;
my $asn_ret = $asn->prepare($asn_common);
bailout("asn1 definition preparation failed: %s", $asn->error()) unless $asn_ret;

### redis connection ###
bailout("redis socket does not exist or is not readable") unless -r $config->{'redis_sock'};
info("trying to connect to redis (timeout 60s)");
my $redis;
eval {
  $redis = new Redis(
    'sock' => $config->{'redis_sock'},
    'reconnect' => 60, 'every' => 1_000_000
  )
};
bailout("cannot connect to redis: %s", $@) if $@;
info("connected to redis on %s", $config->{'redis_sock'});
        
sub debug {
  return unless $config->{'verbose'};
  my $fmt = shift; printf STDERR threads->tid()." [debug] $fmt\n", @_
}
sub info { my $fmt = shift; printf threads->tid()." [info ] $fmt\n", @_ }
sub warning { my $fmt = shift; printf STDERR threads->tid()." [warn ] $fmt\n", @_ }
sub error { my $fmt = shift; printf STDERR threads->tid()." [error] $fmt\n", @_ }
sub bailout { error(@_); exit 1 }

### Queue with cache records for update and delete redis db
### and thread which doing this
my $redisQueue = Thread::Queue->new();
my @threads;
push @threads, threads->create(\&update_redis_record);
sub update_redis_record {
  debug("start thread update_redis_record");
  while (my $cache_ref = $redisQueue->dequeue()) {
    if ($cache_ref->{'delete'}) {
      eval {$redis->del($cache_ref->{'cache_key'})};
      if ($@) {error("delete redis record %s failed: %s", $cache_ref->{'cache_key'}, $@); next}
      info("redis record %s deleted", $cache_ref->{'cache_key'});
    } else {
      eval {$redis->hmset($cache_ref->{'cache_key'}, %$cache_ref)};
      if ($@) {error("update redis record %s failed: %s", $cache_ref->{'cache_key'}, $@); next}
      info("redis record %s updated", $cache_ref->{'cache_key'});
    }
  }
  debug("exit thread update_redis_record");  
}

sub update_cache {
  my $cr = $_[0];

  my $asn_top = $asn->find("OCSPResponse");
  bailout("asn1 cannot find top of structure: %s", $asn->error()) unless $asn_top;

  my $ua = new LWP::UserAgent('agent' => "ocsp_proxy");

  my $req_uri = "http://" . $cr->{'ocsp_responder'};

  my $proxy_req = new HTTP::Request('POST' => $req_uri);
  $proxy_req->header(
    'Host' => $cr->{'ocsp_responder'},
    'Content-Type' => 'application/ocsp-request',
    'Content-Length' => length($cr->{'request'})
  );
  $proxy_req->content($cr->{'request'});
  debug("forwarding ocsp request to %s", $req_uri);
  my $proxy_res = $ua->request($proxy_req);

  unless ($proxy_res->code == 200 &&
    $proxy_res->header('Content-Type') eq "application/ocsp-response") {
      warning("invalid ocsp response (status %d, content-type %s)",
        $proxy_res->code, $proxy_res->header('Content-Type')||"unknown");
    return
  }
  debug("ocsp responder answered");

  my $ocsp_resp = $asn_top->decode($proxy_res->content);

  unless ($ocsp_resp) { warning("cannot decode ocsp response"); return }

  unless ($ocsp_resp->{'responseStatus'} == 0) {
    warning("ocsp response status is %d", $ocsp_resp->{'responseStatus'});
    return
  }

  $asn_top = $asn->find("BasicOCSPResponse");
  bailout("asn1 cannot find top of structure: %s", $asn->error()) unless $asn_top;

  my $basic_resp = $asn_top->decode($ocsp_resp->{'responseBytes'}->{'response'});
  unless ($basic_resp) { warning("cannot decode basic ocsp response"); return }

  my $nonce_ext = 0;
  foreach my $resx (@{$basic_resp->{'tbsResponseData'}->{'responseExtensions'}}) {
    next unless $resx->{'extnID'} eq "1.3.6.1.5.5.7.48.1.2";
    $nonce_ext++
  }

  %$cr = (%$cr,
    'nonce' => $nonce_ext,
    'nextupd' => $basic_resp->{'tbsResponseData'}->{'responses'}->[0]->{'nextUpdate'},
    'thisupd' => $basic_resp->{'tbsResponseData'}->{'responses'}->[0]->{'thisUpdate'},
    'status'  => keys %{$basic_resp->{'tbsResponseData'}->{'responses'}->[0]->{'certStatus'}},
    'response' => $proxy_res->content,
    'lastchecked' => time
  );

  debug("got a valid ocsp response: [this:%d] [next:%d] [status:%s]",
    $cr->{'thisupd'}, $cr->{'nextupd'}, $cr->{'status'});
  1
}

sub refresh_cache {
  for (;;) {

    debug("starting refresh_cache");

    my %cache;
    my @keys;
    eval {@keys = $redis->keys($config->{'rprefix'}."*")};
    if ($@) {error("refresh_cache: cannot connect to redis: %s", $@); return}
    foreach my $cache_key (@keys) {
      eval {%cache = $redis->hgetall($cache_key)};
      if ($@) {error("refresh/redis: %s", $@); return}
      unless ($cache{'ocsp_responder'} && $cache{'request'}) {
        error("removing crippled cache entry %s", $cache_key);
        $cache{'delete'} = 1;
        $redisQueue->enqueue(\%cache);
        next
      }

      $cache{'nextupd'} ||= 0;
      $cache{'thisupd'} ||= 0;
      $cache{'lastchecked'} ||= 0;
      my $intvl = (($cache{'nextupd'}-$cache{'thisupd'})/2+$cache{'thisupd'} > time)?86400:3600;

      if ($cache{'lastchecked'}+$intvl < time) {
        info("refreshing %s", $cache_key);
        if (update_cache(\%cache)) {
          $redisQueue->enqueue(\%cache);
        } else {
            error("refreshing %s failed", $cache_key)
        }
      }
    }

    debug("leaving refresh_cache and sleep for 30 min.");
    sleep 1800;
  }
}
  
### command line switches ###
Getopt::Long::Configure("no_ignore_case");
GetOptions(
    'H=s' => \$config->{'host'},
    'p=i' => \$config->{'port'},
    's=s' => \$config->{'redis_sock'},
    'x=s' => \$config->{'rprefix'},
    'v' => \$config->{'verbose'},
    'h|help' => sub {pod2usage({'-exitval' => 3, '-verbose' => 2})}
) or pod2usage({'-exitval' => 3, '-verbose' => 0});

#$0 = "ocsp_proxy" unless $config->{'verbose'};
$0 = "ocsp_proxy";

push @threads, threads->create(\&refresh_cache);
push @threads, threads->create(\&main);
$_->join foreach @threads;

sub main {
  ### http daemon ###
  my $daemon = new HTTP::Daemon(
      'LocalAddr' => $config->{'host'},
      'LocalPort' => $config->{'port'},
      'Listen' => 5
#      'Reuse' => 1
  ) or bailout("failed starting HTTP::Daemon");
  info("listening on %s:%d", $config->{'host'}, $config->{'port'});

  ### main loop ###
  while (my $con = $daemon->accept) {
    threads->create(\&process_req, $con)->detach();
  }
}

sub process_req {
  my $c = shift;

  my $asn_top = $asn->find("OCSPRequest");
  bailout("asn1 cannot find top of structure: %s", $asn->error()) unless $asn_top;

  info("connection from %s:%d", $c->peerhost, $c->peerport);
  REQ: while (my $r = $c->get_request) {

    if ($r->header('X-Forwarded-For')) {
      info("forward for: %s", $r->header('X-Forwarded-For'));
    }

    unless ($r->method eq 'POST') {
      warning("method is not POST");
      $c->send_error(RC_FORBIDDEN);
      next
    }

    unless ($r->header('Host') || $r->header('X-prune-from-cache')) {
      warning("no 'Host' header found");
      $c->send_error(RC_BAD_REQUEST);
      next
    }

    unless ($r->header('Content-Type') eq "application/ocsp-request") {
      warning("Content-Type is not 'application/ocsp-request'");
      $c->send_error(RC_BAD_REQUEST);
      next
    }

    my $ocsp_req = $asn_top->decode($r->content);

    unless ($ocsp_req) {
      warning("cannot parse ocsp request");
      $c->send_error(RC_BAD_REQUEST);
      next
    }

    if (scalar @{$ocsp_req->{'tbsRequest'}->{'requestList'}} > 1) {
      warning("multiple requests detected -> pass through");
      my $ua = new LWP::UserAgent('agent' => "ocsp_proxy");
      my $proxy_req = new HTTP::Request('POST' => "http://".$r->header('Host'));
      $proxy_req->header(%{$r->headers});
      $proxy_req->content($r->content);
      debug("forwarding ocsp request to %s", $r->header('Host'));
      my $proxy_res = $ua->request($proxy_req);
      my $client_res = new HTTP::Response($proxy_res->code);
      $client_res->header(%{$proxy_res->headers});
      $client_res->content($proxy_res->content);
      $c->send_response($client_res);
      next
    }

    my $issuer_key_hash = unpack("H*", $ocsp_req->{'tbsRequest'}->{'requestList'}->[0]->{'reqCert'}->{'issuerKeyHash'});
    my $cert_serial = Math::BigInt->new($ocsp_req->{'tbsRequest'}->{'requestList'}->[0]->{'reqCert'}->{'serialNumber'})->as_hex;
    $cert_serial =~ s/^0x//;

    my $cache_key = $config->{'rprefix'} . $issuer_key_hash . '_' . $cert_serial;
    debug("cache key is %s", $cache_key);

    my %cache;
    eval { %cache = $redis->hgetall($cache_key) };
    bailout("redis connection failed: %s", $@) if $@;

    if ($r->header('X-prune-from-cache')) {
      info("removing %s from cache", $cache_key);
      $cache{'delete'} = 1;
      $redisQueue->enqueue(\%cache);
      $c->send_error(RC_GONE);
      next
    }

    unless (%cache && ($cache{'nextupd'} or 0) > time && \
      ($cache{'thisupd'} or 0) > 0 && $cache{'request'} && $cache{'response'}) {
      debug("cache needs update");
      %cache = ('cache_key' => $cache_key, 'ocsp_responder' => $r->header('Host'), 'request' => $r->content);
      if (update_cache(\%cache)) {
        unless ($cache{'nonce'}) {
          $redisQueue->enqueue(\%cache);
        } else {
          warning("responder answered with a nonce, cannot cache those")
        }
      } else {
        error("cache is invalid and cannot get valid data from ocsp responder");
        $cache{'delete'} = 1;
        $redisQueue->enqueue(\%cache);
        $c->send_error(RC_SERVICE_UNAVAILABLE);
        next REQ
      }
    }

    debug("sending response");
    my $client_res = new HTTP::Response(RC_OK);
    $client_res->header(
      'Content-Type' => 'application/ocsp-response',
      'Content-Length' => length $cache{'response'},
      'Date' => strftime("%a, %d %b %Y %T %Z", localtime),
      'Expires' => strftime("%a, %d %b %Y %T %Z", localtime $cache{'nextupd'}),
      'Last-Modified' => strftime("%a, %d %b %Y %T %Z", localtime $cache{'thisupd'})
    );
    $client_res->content($cache{'response'});
    $c->send_response($client_res);
  }

  debug("disconnecting %s:%d", $c->peerhost, $c->peerport);
  $c->close;
  undef $c
}


__END__

=head1 NAME

ocsp_proxy - a caching ocsp proxy :)

=head1 VERSION

 0.4.1

=head1 SYNOPSIS

 ocsp_proxy.pl

=head1 OPTIONS

=over 8

=item B<-H> I<address>

bind to I<address>

=item B<-p> I<port>

bind to I<port>

=item B<-s> I<socket>

select redis socket

=item B<-x> I<prefix>

select redis prefix

=item B<-v>

be verbose

=back

=head1 DESCRIPTION

This daemon acts as a proxy for ocsp requests.
You may use it together with apache httpd / mod_ssl:

 SSLOCSPProxyURL http://localhost:8888/

OCSP responses are stored in a redis db and are refreshed on daily basis, or
hourly if the validity period is at half-time.

=head1 DEPENDENCIES

=over 8

=item L<HTTP::Daemon>

=item L<HTTP::Status>

=item L<HTTP::Response>

=item L<LWP>

=item L<Redis>

=item L<Convert::ASN1>

=back

=head1 AUTHOR

fork from ocsp_proxy from Philippe Kueck <projects at unixadm dot org>

=head1 LICENSE

LGPL 3

=cut
