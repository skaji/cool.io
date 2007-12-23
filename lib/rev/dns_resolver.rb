require File.dirname(__FILE__) + '/../rev'

#--
# Gimpy hacka asynchronous DNS resolver
#
# Word to the wise: I don't know what I'm doing here.  This was cobbled together as
# best I could with extremely limited knowledge of the DNS format.  There's obviously
# a ton of stuff it doesn't support (like TCP).
#
# If you do know what you're doing with DNS, feel free to improve this! 
#++

module Rev
  class DNSResolver < IOWatcher
    RESOLV_CONF = '/etc/resolv.conf'
    HOSTS = '/etc/hosts'
    DNS_PORT = 53
    DATAGRAM_SIZE = 512
    TIMEOUT = 3
    RETRIES = 3

    def self.hosts(host)
      hosts = {}
      File.open(HOSTS).each_line do |host_entry|
        entries = host_entry.gsub(/#.*$/, '').gsub(/\s+/, ' ').split(' ')
        addr = entries.shift
        entries.each { |e| hosts[e] ||= addr }
      end

      hosts[host]
    end

    def initialize(hostname, *nameservers)
      if nameservers.nil? or nameservers.empty?
        nameservers = File.read(RESOLV_CONF).scan(/^\s*nameserver\s+([0-9.:]+)/).flatten
        raise RuntimeError, "no nameservers found in #{RESOLV_CONF}" if nameservers.empty?
      end

      @nameservers = nameservers
      @request = request_message hostname
      @question = request_question hostname

      @socket = UDPSocket.new
      @timer = Timeout.new(self)
      super(@socket)
    end

    def attach(evloop)
      if @hostname
        on_success @hostname
        return self
      end

      send_request
      @timer.attach(evloop)
      super
    end

    def detach
      @timer.detach if @timer.attached?
      super
    end

    # Called by the subclass when the DNS response is available
    def on_readable
      datagram = @socket.recvfrom(DATAGRAM_SIZE).first
      address = response_address datagram rescue nil
      address ? on_success(address) : on_failure
      detach
    end

    # Called when the name has successfully resolved to an address
    def on_success(address)
    end

    # Called when we receive a response indicating the name didn't resolve
    def on_failure
    end

    # Called if we don't receive a response
    def on_timeout
    end

    # Send a request to the DNS server
    def send_request
      @socket.connect @nameservers.first, DNS_PORT
      @socket.send @request, 0
    end

    #########
    protected
    #########

    def request_message(hostname)
      # Standard query header
      message = "\000\002\001\000"

      # One entry
      qdcount = 1

      # No answer, authority, or additional records
      ancount = nscount = arcount = 0 

      message << [qdcount, ancount, nscount, arcount].pack('nnnn')
      message << request_question(hostname)
   end

    def request_question(hostname)
      # Query name
      message = hostname.split('.').map { |s| [s.size].pack('C') << s }.join + "\000"

      # Host address query
      qtype = 1

      # Internet query
      qclass = 1

      message << [qtype, qclass].pack('nn')
    end

    def response_address(message)
      # Confirm the ID field
      id = message[0..1].unpack('n').first.to_i
      return unless id == 2

      # Check the QR value and confirm this message is a response
      qr = message[2].unpack('B1').first.to_i
      return unless qr == 1

      # Check the RCODE and ensure there wasn't an error
      rcode = message[3].unpack('B8').first[4..7].to_i(2)
      return unless rcode == 0

      # Extract the question and answer counts
      qdcount, ancount = message[4..7].unpack('nn').map { |n| n.to_i }

      # We only asked one question
      return unless qdcount == 1
      message = message[12..message.size] # slice! would be nice but I think I hit a 1.9 bug...

      # Make sure it's the same question
      return unless message[0..(@question.size-1)] == @question
      message = message[@question.size..message.size]

      # Extract the RDLENGTH
      while not message.empty?
        type = message[2..3].unpack('n').first.to_i
        rdlength = message[10..11].unpack('n').first.to_i
        rdata = message[12..(12 + rdlength - 1)]
        message = message[(12+rdlength)..message.size]

        # Only IPv4 supported
        next unless rdlength == 4

        return rdata.unpack('CCCC').join('.') if type == 1
      end

      nil
    end

    class Timeout < TimerWatcher
      def initialize(resolver)
        @resolver = resolver
        @attempts = 0
        super(TIMEOUT, true)
      end

      def on_timer
        @attempts += 1
        return @resolver.send_request if @attempts <= RETRIES 
        
        @resolver.on_timeout
        detach
      end
    end
  end
end