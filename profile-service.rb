#!/usr/bin/ruby

# PayloadIdentifier: identifies a payload through its lifetime (all versions)
# PayloadType: kind of payload, do not change
# PayloadDisplayName: display name, shown on install and inspection
# PayloadDescription: longer description to go with display name

=begin

NOTES

The use of certificates has been simplified for the sake of providing a
simple example.  We'll just be using a root and ssl certificate.  The ssl
certificate will be used for:
- TLS cert for the profile service
- RA cert for the simplified SCEP service 
- Profile signing cert for profiles generated by the service


FIX UPS

remove more debug logging or make it optional, just like dumping payloads
describe the apple certificate hierarchy for device certificates


=end
require "rubygems"

require 'webrick'
require 'webrick/https'
include WEBrick

require 'openssl'

require 'set'

# http://plist.rubyforge.org

$:.unshift(File.dirname(__FILE__) + "/plist/lib")
require 'plist'

# http://UUIDTools.rubyforge.org
$:.unshift(File.dirname(__FILE__) + "/uuidtools/lib")
require 'uuidtools'

# explicitly set this to host ip or name if more than one interface exists
$address = "AUTOMATIC"

puts($address);

def local_ip
    # turn off reverse DNS resolution temporarily
    orig, Socket.do_not_reverse_lookup = Socket.do_not_reverse_lookup, true  

    UDPSocket.open do |s|
        s.connect '0.0.0.1', 1
        s.addr.last
    end
ensure
    Socket.do_not_reverse_lookup = orig
end


$rsa_key_size = 2048

$root_cert_file = "ca_cert.pem"
$root_cert = nil
$root_key_file = "ca_private.pem"
$root_key = nil

$serial_file = "serial"
$serial = 100

$ssl_key_file = "ssl_private.pem"
$ssl_key = nil
$ssl_cert_file = "ssl_cert.pem"
$ssl_cert = nil

$ra_key_file = "ra_private.pem"
$ra_key = nil
$ra_cert_file = "ra_cert.pem"
$ra_cert = nil

$issued_first_profile = Set.new

def issue_cert(dn, key, serial, not_before, not_after, extensions, issuer, issuer_key, digest)
    cert = OpenSSL::X509::Certificate.new
    issuer = cert unless issuer
    issuer_key = key unless issuer_key
    cert.version = 2
    cert.serial = serial
    cert.subject = dn
    cert.issuer = issuer.subject
    cert.public_key = key.public_key
    cert.not_before = not_before
    cert.not_after = not_after
    ef = OpenSSL::X509::ExtensionFactory.new
    ef.subject_certificate = cert
    ef.issuer_certificate = issuer
    extensions.each { |oid, value, critical|
        cert.add_extension(ef.create_extension(oid, value, critical))
    }
    cert.sign(issuer_key, digest)
    cert
end


def issueCert(req, validdays)
    req = OpenSSL::X509::Request.new(req)
    cert = issue_cert(req.subject, req.public_key, $serial, Time.now, Time.now+(86400*validdays), 
        [ ["keyUsage","digitalSignature,keyEncipherment",true] ],
        $root_cert, $root_key, OpenSSL::Digest::SHA1.new)
    $serial += 1
    File.open($serial_file, "w") { |f| f.write $serial.to_s }
    puts("请求证书");
    cert
end


require 'socket'

def local_ip
  orig, Socket.do_not_reverse_lookup = Socket.do_not_reverse_lookup, true  # turn off reverse DNS resolution temporarily

  UDPSocket.open do |s|
    s.connect '17.244.0.1', 1
    s.addr.last
  end
ensure
  Socket.do_not_reverse_lookup = orig
end



def service_address(request)
    address = "localhost"
    if request.addr.size > 0
        host, port = request.addr[2], request.addr[1]
    end
    host.to_s + ":" + port.to_s
end


=begin
        *** PAYLOAD SECTION ***
=end

def general_payload
    payload = Hash.new
    payload['PayloadVersion'] = 1 # do not modify
    payload['PayloadUUID'] = UUIDTools::UUID.random_create().to_s # should be unique

    # string that show up in UI, customisable
    payload['PayloadOrganization'] = "ACME Inc."
    payload
end


def profile_service_payload(request, challenge)
    payload = general_payload()

    payload['PayloadType'] = "Profile Service" # do not modify
    payload['PayloadIdentifier'] = "com.acme.mobileconfig.profile-service"

    # strings that show up in UI, customisable
    payload['PayloadDisplayName'] = "ACME Profile Service"
    payload['PayloadDescription'] = "Install this profile to enroll for secure access to ACME Inc."

    payload_content = Hash.new
    payload_content['URL'] = "http://" + service_address(request) + "/profile"
    payload_content['DeviceAttributes'] = [
        "UDID", 
        "VERSION"
=begin
        "PRODUCT",              # ie. iPhone1,1 or iPod2,1
        "MAC_ADDRESS_EN0",      # WiFi MAC address
        "DEVICE_NAME",          # given device name "iPhone"
        # Items below are only available on iPhones
        "IMEI",
        "ICCID"
=end
        ];
    if (challenge && !challenge.empty?)
        payload_content['Challenge'] = challenge
    end

    payload['PayloadContent'] = payload_content
    puts(payload);
    Plist::Emit.dump(payload)
end


def scep_cert_payload(request, purpose, challenge)
    payload = general_payload()

    payload['PayloadIdentifier'] = "com.acme.encryption-cert-request"
    payload['PayloadType'] = "com.apple.security.scep" # do not modify

    # strings that show up in UI, customisable
    payload['PayloadDisplayName'] = purpose
    payload['PayloadDescription'] = "Provides device encryption identity"

    payload_content = Hash.new
    payload_content['URL'] = "https://" + service_address(request) + "/scep"
=begin
    # scep instance NOTE: required for MS SCEP servers
    payload_content['Name'] = "" 
=end
    payload_content['Subject'] = [ [ [ "O", "ACME Inc." ] ], 
        [ [ "CN", purpose + " (" + UUIDTools::UUID.random_create().to_s + ")" ] ] ];
    if (!challenge.empty?)
        payload_content['Challenge'] = challenge
    end
    payload_content['Keysize'] = $rsa_key_size
    payload_content['Key Type'] = "RSA"
    payload_content['Key Usage'] = 5 # digital signature (1) | key encipherment (4)
    # NOTE: MS SCEP server will only issue signature or encryption, not both

    # SCEP can run over HTTP, as long as the CA cert is verified out of band
    # Below we achieve this by adding the fingerprint to the SCEP payload
    # that the phone downloads over HTTPS during enrollment.
=begin
    # Disabled until the following is fixed: <rdar://problem/7172187> SCEP various fixes
    payload_content['CAFingerprint'] = StringIO.new(OpenSSL::Digest::SHA1.new($root_cert.to_der).digest)
=end

    payload['PayloadContent'] = payload_content;
    payload
end


def encryption_cert_payload(request, challenge)
    payload = general_payload()
    
    payload['PayloadIdentifier'] = "com.acme.encrypted-profile-service"
    payload['PayloadType'] = "Configuration" # do not modify
  
    # strings that show up in UI, customisable
    payload['PayloadDisplayName'] = "Profile Service Enroll"
    payload['PayloadDescription'] = "Enrolls identity for the encrypted profile service"

    payload['PayloadContent'] = [scep_cert_payload(request, "Profile Service", challenge)];
    Plist::Emit.dump(payload)
end


def client_cert_configuration_payload(request)

    webclip_payload = general_payload()

    webclip_payload['PayloadIdentifier'] = "com.acme.webclip.intranet"
    webclip_payload['PayloadType'] = "com.apple.webClip.managed" # do not modify

    # strings that show up in UI, customisable
    webclip_payload['PayloadDisplayName'] = "ACME Inc."
    webclip_payload['PayloadDescription'] = "Creates a link to the ACME intranet on the home screen"
    
    # allow user to remove webclip
    webclip_payload['IsRemovable'] = true
    
    # the link
    webclip_payload['Label'] = "ACME Inc."
    webclip_payload['URL'] = "https://" + service_address(request).split(":")[0] # + ":4443/"

    client_cert_payload = scep_cert_payload(request, "Client Authentication", "foo");
    
    Plist::Emit.dump([webclip_payload, client_cert_payload])
end


def vpn_configuration_payload(request)

    intranet_webclip_payload = general_payload()

    intranet_webclip_payload['PayloadIdentifier'] = "com.acme.webclip.intranet"
    intranet_webclip_payload['PayloadType'] = "com.apple.webClip.managed" # do not modify

    # strings that show up in UI, customisable
    intranet_webclip_payload['PayloadDisplayName'] = "ACME Inc."
    intranet_webclip_payload['PayloadDescription'] = "Creates a link to the ACME intranet on the home screen"
    intranet_webclip_payload['IsRemovable'] = true
    intranet_webclip_payload['Label'] = "ACME Inc."
    intranet_webclip_payload['URL'] = "https://www.intranet.acme.com/"


    vpn_cert_payload = scep_cert_payload(request, "VPN", "foo");
    
    vpn_payload = general_payload()
    vpn_payload['PayloadIdentifier'] = "com.acme.vpn.intranet"
    vpn_payload['PayloadType'] = "com.apple.vpn.managed"
    vpn_payload['PayloadDisplayName'] = "VPN (ACME North America)"
    vpn_payload['PayloadDescription'] = "Configures VPN settings, including authentication."
    vpn_payload['VPNType'] = "IPSec"

    vpn_settings = Hash.new
    vpn_settings['AuthenticationMethod'] = "Certificate"
    vpn_settings['OnDemandEnabled'] = 1
    vpn_settings['OnDemandMatchDomainsAlways'] = ["intranet.acme.com"]
    #vpn_settings['OnDemandMatchDomainsNever'] = 
    #vpn_settings['OnDemandMatchDomainsOnRetry'] = 
    vpn_settings['PayloadCertificateUUID'] = payload2['PayloadUUID'].to_s
    vpn_settings['RemoteAddress'] = service_address(request).split(":")[0]
    vpn_settings['XAuthEnabled'] = 1
    #  vpn_settings['XAuthName'] = "foo"
    vpn_settings['PromptForVPNPIN'] = false
    #  vpn_settings['XAuthPasswordEncryption'] = "just say no"
    #  vpn_settings['XAuthPassword'] = "foo"
    
    vpn_payload['IPSec'] = vpn_settings

    passcode_policy_payload = general_payload()
    passcode_policy_payload['PayloadIdentifier'] = "com.acme.passcodepolicy"
    passcode_policy_payload['PayloadType'] = "com.apple.mobiledevice.passwordpolicy"
    passcode_policy_payload['PayloadDisplayName'] = "Passcode Policy"
    passcode_policy_payload['PayloadDescription'] = "Configures passcode policy."
    passcode_policy_payload['maxFailedAttempts'] = 10
    passcode_policy_payload['minLength'] = 6
    passcode_policy_payload['maxPINAgeInDays'] = 90
    passcode_policy_payload['requireAlphanumeric'] = false
    passcode_policy_payload['minComplexChars'] = 0
    passcode_policy_payload['maxInactivity'] = 5
    passcode_policy_payload['forcePIN'] = true
    passcode_policy_payload['allowSimple'] = false
    passcode_policy_payload['pinHistory'] = 1
    passcode_policy_payload['maxGracePeriod'] = 5

    Plist::Emit.dump([intranet_webclip_payload, vpn_cert_payload, vpn_payload, passcode_policy_payload])
end


def configuration_payload(request, encrypted_content)
    payload = general_payload()
    payload['PayloadIdentifier'] = "com.acme.intranet"
    payload['PayloadType'] = "Configuration" # do not modify

    # strings that show up in UI, customisable
    payload['PayloadDisplayName'] = "Encrypted Config"
    payload['PayloadDescription'] = "Access to the ACME Intranet"
    payload['PayloadExpirationDate'] = Date.today # expire today, for demo purposes

    payload['EncryptedPayloadContent'] = StringIO.new(encrypted_content)
    Plist::Emit.dump(payload)
end


def init

    if $address == "AUTOMATIC"
        $address = local_ip
        print "*** detected address #{$address} ***\n"
    end

    ca_cert_ok = false
    ra_cert_ok = false
    ssl_cert_ok = false
    
    begin
        $root_key = OpenSSL::PKey::RSA.new(File.read($root_key_file))
        $root_cert = OpenSSL::X509::Certificate.new(File.read($root_cert_file))
        $serial = File.read($serial_file).to_i
        ca_cert_ok = true
        $ra_key = OpenSSL::PKey::RSA.new(File.read($ra_key_file))
        $ra_cert = OpenSSL::X509::Certificate.new(File.read($ra_cert_file))
        ra_cert_ok = true
        $ssl_key = OpenSSL::PKey::RSA.new(File.read($ssl_key_file))
        $ssl_cert = OpenSSL::X509::Certificate.new(File.read($ssl_cert_file))
        $ssl_cert.extensions.each { |e,ssl_cert_ok| 
            e.value == "DNS:#{$address}" && ssl_cert_ok = true
        }
        ssl_cert_ok = true

        print "*** 如果服务器地址变更 要重新生成ssl证书 ***\n"
        if !ssl_cert_ok
            print "*** server address changed; issuing new ssl certificate ***\n"
            raise
        end
    rescue
        if !ca_cert_ok
        then
            $root_key = OpenSSL::PKey::RSA.new($rsa_key_size)
            $root_cert = issue_cert( OpenSSL::X509::Name.parse(
                "/O=None/CN=ACME Root CA (#{UUIDTools::UUID.random_create().to_s})"),
                $root_key, 1, Time.now, Time.now+(86400*365), 
                [ ["basicConstraints","CA:TRUE",true],
                ["keyUsage","Digital Signature,keyCertSign,cRLSign",true] ],
                nil, nil, OpenSSL::Digest::SHA1.new)
            $serial = 100

            File.open($root_key_file, "w") { |f| f.write $root_key.to_pem }
            File.open($root_cert_file, "w") { |f| f.write $root_cert.to_pem }
            File.open($serial_file, "w") { |f| f.write $serial.to_s }
        end
        
        if !ra_cert_ok
        then
            $ra_key = OpenSSL::PKey::RSA.new($rsa_key_size)
            $ra_cert = issue_cert( OpenSSL::X509::Name.parse(
                "/O=None/CN=ACME SCEP RA"),
                $ra_key, $serial, Time.now, Time.now+(86400*365), 
                [ ["basicConstraints","CA:TRUE",true],
                ["keyUsage","Digital Signature,keyEncipherment",true] ],
                $root_cert, $root_key, OpenSSL::Digest::SHA1.new)
            $serial += 1
            File.open($ra_key_file, "w") { |f| f.write $ra_key.to_pem }
            File.open($ra_cert_file, "w") { |f| f.write $ra_cert.to_pem }
        end
        
        if !ssl_cert_ok
        then
            puts("ssl cert  not ok")
            $ssl_key = OpenSSL::PKey::RSA.new($rsa_key_size)
            $ssl_cert = issue_cert( OpenSSL::X509::Name.parse("/O=None/CN=ACME Profile Service"),
                $ssl_key, $serial, Time.now, Time.now+(86400*365), 
                [   
                    ["keyUsage","Digital Signature",true] ,
                    ["subjectAltName", "DNS:" + $address, true]
                ],
                $root_cert, $root_key, OpenSSL::Digest::SHA1.new)
        end

        $serial += 1
        File.open($serial_file, "w") { |f| f.write $serial.to_s }
        File.open($ssl_key_file, "w") { |f| f.write $ssl_key.to_pem }
        File.open($ssl_cert_file, "w") { |f| f.write $ssl_cert.to_pem }
    end
end





=begin
*************************************************************************
    
*************************************************************************
=end

init()

world = WEBrick::HTTPServer.new(
  :Port            => 8443,
  :DocumentRoot    => Dir::pwd + "/htdocs",
  :SSLEnable       => true,
  :SSLVerifyClient => OpenSSL::SSL::VERIFY_NONE,
  :SSLCertificate  => $ssl_cert,
  :SSLPrivateKey   => $ssl_key
)

world.mount_proc("/") { |req, res|
    res['Content-Type'] = "text/html"
    res.body = <<WELCOME_MESSAGE
    
<style>
body { margin:40px 40px;font-family:Helvetica;}
h1 { font-size:80px; }
p { font-size:60px; }
a { text-decoration:none; }
</style>
<h1 >ACME Inc. Profile Service</h1>
<p>If you had to accept the certificate accessing this page, you should
download the <a href="/CA">root certificate</a> and install it so it becomes trusted. 
<p>We are using a self-signed
certificate here, for production it should be issued by a known CA.
<p>After that, go ahead and <a href="/enroll">enroll</a>
WELCOME_MESSAGE

}

world.mount_proc("/CA") { |req, res|
    res['Content-Type'] = "application/x-x509-ca-cert"
    res.body = $root_cert.to_der
}

world.mount_proc("/enroll") { |req, res|
    HTTPAuth.basic_auth(req, res, "realm") {|user, password|
        user == 'apple' && password == 'apple'
    }

    res['Content-Type'] = "application/x-apple-aspen-config"
    configuration = profile_service_payload(req, "signed-auth-token")

    res.body = configuration
    # signed_profile = OpenSSL::PKCS7.sign($ssl_cert, $ssl_key, 
    #         configuration, [], OpenSSL::PKCS7::BINARY)
    # res.body = signed_profile.to_der

}

world.mount_proc("/profile") { |req, res|
    puts("get profile");
    # verify CMS blob, but don't check signer certificate
    p7sign = OpenSSL::PKCS7.new(req.body)
    store = OpenSSL::X509::Store.new
    p7sign.verify(nil, store, nil, OpenSSL::PKCS7::NOVERIFY)
    signers = p7sign.signers
    
    # this should be checking whether the signer is a cert we issued
    # 
    if (signers[0].issuer.to_s == $root_cert.subject.to_s)
        print "Request from cert with serial #{signers[0].serial}"
            " seen previously: #{$issued_first_profile.include?(signers[0].serial.to_s)}"
            " (profiles issued to #{$issued_first_profile.to_a}) \n"
        if ($issued_first_profile.include?(signers[0].serial.to_s))
          res.set_redirect(WEBrick::HTTPStatus::MovedPermanently, "/enroll")
            print res
        else
            $issued_first_profile.add(signers[0].serial.to_s)
            payload = client_cert_configuration_payload(req)
                        # vpn_configuration_payload(req)
                        
            #File.open("payload", "w") { |f| f.write payload }
            encrypted_profile = OpenSSL::PKCS7.encrypt(p7sign.certificates,
                payload, OpenSSL::Cipher::Cipher::new("des-ede3-cbc"), 
                OpenSSL::PKCS7::BINARY)
            configuration = configuration_payload(req, encrypted_profile.to_der)
        end
    else
        #File.open("signeddata", "w") { |f| f.write p7sign.data }
        device_attributes = Plist::parse_xml(p7sign.data)
        #print device_attributes
        
=begin
        # Limit issuing of profiles to one device and validate challenge
        if device_attributes['UDID'] == "213cee5cd11778bee2cd1cea624bcc0ab813d235" &&
            device_attributes['CHALLENGE'] == "signed-auth-token"
        end
=end
        configuration = encryption_cert_payload(req, "")
    end

    if !configuration || configuration.empty?
        raise "you lose"
    else
		# we're either sending a configuration to enroll the profile service cert
		# or a profile specifically for this device
		res['Content-Type'] = "application/x-apple-aspen-config"
    
        signed_profile = OpenSSL::PKCS7.sign($ssl_cert, $ssl_key, 
            configuration, [], OpenSSL::PKCS7::BINARY)
        res.body = signed_profile.to_der
        File.open("profile.der", "w") { |f| f.write signed_profile.to_der }
    end
}

=begin
This is a hacked up SCEP service to simplify the profile service demonstration
but clearly doesn't perform any of the security checks a regular service would
enforce.
=end
include OpenSSL::ASN1
world.mount_proc("/scep"){ |req, res|

  print "Query #{req.query_string}\n"
  query = HTTPUtils::parse_query(req.query_string)
  
  if query['operation'] == "GetCACert"
    res['Content-Type'] = "application/x-x509-ca-ra-cert"
    #scep_certs = OpenSSL::PKCS7.new()
    #scep_certs.type="signed"
    #scep_certs.certificates=[$root_cert, $ra_cert]
	scep_certs = Sequence.new([
	  OpenSSL::ASN1::ObjectId.new('1.2.840.113549.1.7.2'),
	  ASN1Data.new([
		Sequence.new([
		  OpenSSL::ASN1::Integer.new(1),
		  OpenSSL::ASN1::Set.new([
		  ]),
		  Sequence.new([
			OpenSSL::ASN1::ObjectId.new('1.2.840.113549.1.7.1')
		  ]),
		  ASN1Data.new([
			decode($root_cert.to_der),
			decode($ra_cert.to_der)
		  ], 0, :CONTEXT_SPECIFIC),


		  ASN1Data.new([
		  ], 1, :CONTEXT_SPECIFIC),
		  OpenSSL::ASN1::Set.new([
		  ])
		])
	  ], 0, :CONTEXT_SPECIFIC)
	])
    res.body = scep_certs.to_der



  else 
    if query['operation'] == "GetCACaps"
        res['Content-Type'] = "text/plain"
        res.body = "POSTPKIOperation\nSHA-1\nDES3\n"
    else
      if query['operation'] == "PKIOperation"
        p7sign = OpenSSL::PKCS7.new(req.body)
        store = OpenSSL::X509::Store.new
        p7sign.verify(nil, store, nil, OpenSSL::PKCS7::NOVERIFY)
        signers = p7sign.signers
        p7enc = OpenSSL::PKCS7.new(p7sign.data)
        csr = p7enc.decrypt($ra_key, $ra_cert)
        cert = issueCert(csr, 1)
        #degenerate_pkcs7 = OpenSSL::PKCS7.new()
        #degenerate_pkcs7.type="signed"
        #degenerate_pkcs7.certificates=[cert]
		degenerate_pkcs7 = Sequence.new([
		  OpenSSL::ASN1::ObjectId.new('1.2.840.113549.1.7.2'),
		  ASN1Data.new([
			Sequence.new([
			  OpenSSL::ASN1::Integer.new(1),
			  OpenSSL::ASN1::Set.new([
			  ]),
			  Sequence.new([
				OpenSSL::ASN1::ObjectId.new('1.2.840.113549.1.7.1')
			  ]),
			  ASN1Data.new([
				decode(cert.to_der)
			  ], 0, :CONTEXT_SPECIFIC),


			  ASN1Data.new([
			  ], 1, :CONTEXT_SPECIFIC),
			  OpenSSL::ASN1::Set.new([
			  ])
			])
		  ], 0, :CONTEXT_SPECIFIC)
		])
		enc_cert = OpenSSL::PKCS7.encrypt(p7sign.certificates, degenerate_pkcs7.to_der,
            OpenSSL::Cipher::Cipher::new("des-ede3-cbc"), OpenSSL::PKCS7::BINARY)
        reply = OpenSSL::PKCS7.sign($ra_cert, $ra_key, enc_cert.to_der, [], OpenSSL::PKCS7::BINARY)
        res['Content-Type'] = "application/x-pki-message"
        res.body = reply.to_der
       end
     end
  end
}


secret = WEBrick::HTTPServer.new(
  :Port            => 4443,
  :DocumentRoot    => Dir::pwd,
  :SSLEnable       => true,
  :SSLCertificate  => $ssl_cert,
  :SSLPrivateKey   => $ssl_key,
  :SSLVerifyClient => OpenSSL::SSL:: VERIFY_PEER|OpenSSL::SSL::VERIFY_FAIL_IF_NO_PEER_CERT,
  :SSLClientCA     => $root_cert,
  :SSLCertName     => nil # name for auto-gen
#  :SSLVerifyDepth       => nil,
#  :SSLVerifyCallback    => nil,   # custom verification
#  :SSLCertificateStore  => nil,
)

=begin
        meta["SSL_CLIENT_CERT"] = @client_cert ? @client_cert.to_pem : ""
        if @client_cert_chain
          @client_cert_chain.each_with_index{|cert, i|
            meta["SSL_CLIENT_CERT_CHAIN_#{i}"] = cert.to_pem
          }
        end
        meta["SSL_CIPHER"] = @cipher[0]
        meta["SSL_PROTOCOL"] = @cipher[1]
        meta["SSL_CIPHER_USEKEYSIZE"] = @cipher[2].to_s
        meta["SSL_CIPHER_ALGKEYSIZE"] = @cipher[3].to_s
=end
secret.mount_proc("/") { |req, res|
#    client_cert = OpenSSL::X509::Certificate.new(req.meta_vars['SSL_CLIENT_CERT'])
#{client_cert.issuer.to_s}
    print "#{req.meta_vars['SSL_CLIENT_CERT'].to_s}\n"
    print "#{req.meta_vars['SSL_SERVER_CERT'].to_s}\n"
    res['Content-Type'] = "text/html"
    res.body = <<WELCOME
<style>
body { margin:40px 40px;font-family:Helvetica;}
h1 { font-size:80px; }
p { font-size:60px; }
a { text-decoration:none; }
</style>
<h1 >ACME Inc. Internal</h1>
<p>Hello #{req.meta_vars['SSL_CLIENT_CERT'].to_s}
x
<p>If you can read this, we are cool.
<p>This connection: #{req.meta_vars["SSL_CIPHER"]}
#{req.meta_vars["SSL_PROTOCOL"]}
#{req.meta_vars["SSL_CIPHER_USEKEYSIZE"]}
#{req.meta_vars["SSL_CIPHER_ALGKEYSIZE"]}
WELCOME
}

trap(:INT) do
  world.shutdown
#  secret.shutdown
end

world_t = Thread.new {
  Thread.current.abort_on_exception = true
  world.start
}

=begin
secret_t = Thread.new {
    Thread.current.abort_on_exception = true
    secret.start
}
=end

world_t.join
#secret_t.join