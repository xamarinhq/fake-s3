require 'webrick'
require 'fakes3/file_store'
require 'fakes3/xml_adapter'
require 'fakes3/bucket_query'
require 'fakes3/unsupported_operation'
require 'fakes3/errors'

module FakeS3
  class Request
    CREATE_BUCKET = "CREATE_BUCKET"
    LIST_BUCKETS = "LIST_BUCKETS"
    LS_BUCKET = "LS_BUCKET"
    HEAD = "HEAD"
    STORE = "STORE"
    COPY = "COPY"
    GET = "GET"
    GET_ACL = "GET_ACL"
    SET_ACL = "SET_ACL"
    MOVE = "MOVE"
    DELETE_OBJECT = "DELETE_OBJECT"
    DELETE_BUCKET = "DELETE_BUCKET"

    attr_accessor :bucket,:object,:type,:src_bucket,
                  :src_object,:method,:webrick_request,
                  :path,:is_path_style,:query,:http_verb

    def inspect
      puts "-----Inspect FakeS3 Request"
      puts "Type: #{@type}"
      puts "Is Path Style: #{@is_path_style}"
      puts "Request Method: #{@method}"
      puts "Bucket: #{@bucket}"
      puts "Object: #{@object}"
      puts "Src Bucket: #{@src_bucket}"
      puts "Src Object: #{@src_object}"
      puts "Query: #{@query}"
      puts "-----Done"
    end
  end

  class Servlet < WEBrick::HTTPServlet::AbstractServlet
    class PostRequest
      attr_reader :header
      def initialize(headers, body)
        @header = headers
        @body = body
      end

      def body
        yield @body if block_given?
        @body
      end
    end

    def initialize(server,store,hostname)
      super(server)
      @store = store
      @hostname = hostname
      @root_hostnames = [hostname,'localhost','s3.amazonaws.com','s3.localhost']
    end

    def do_OPTIONS(request, response)
      add_cors_headers(request, response)
      super
    end

    def do_GET(request, response)
      add_cors_headers(request, response)
      s_req = normalize_request(request)

      case s_req.type
      when 'LIST_BUCKETS'
        response.status = 200
        response['Content-Type'] = 'application/xml'
        buckets = @store.buckets
        response.body = XmlAdapter.buckets(buckets)
      when 'LS_BUCKET'
        bucket_obj = @store.get_bucket(s_req.bucket)
        if bucket_obj
          response.status = 200
          response['Content-Type'] = "application/xml"
          query = {
            :marker => s_req.query["marker"] ? s_req.query["marker"].to_s : nil,
            :prefix => s_req.query["prefix"] ? s_req.query["prefix"].to_s : nil,
            :max_keys => s_req.query["max_keys"] ? s_req.query["max_keys"].to_s : nil,
            :delimiter => s_req.query["delimiter"] ? s_req.query["delimiter"].to_s : nil
          }
          bq = bucket_obj.query_for_range(query)
          response.body = XmlAdapter.bucket_query(bq)
        else
          response.status = 404
          response.body = XmlAdapter.error_no_such_bucket(s_req.bucket)
          response['Content-Type'] = "application/xml"
        end
      when 'GET_ACL'
        response.status = 200
        response.body = XmlAdapter.acl()
        response['Content-Type'] = 'application/xml'
      when 'GET'
        real_obj = @store.get_object(s_req.bucket,s_req.object,request)
        if !real_obj
          response.status = 404
          response.body = ""
          return
        end

        response.status = 200
        response['Content-Type'] = real_obj.content_type
        stat = File::Stat.new(real_obj.io.path)

        response['Last-Modified'] = stat.mtime.iso8601()
        response['Etag'] = "\"#{real_obj.md5}\""
        response['Accept-Ranges'] = "bytes"
        response['Last-Ranges'] = "bytes"

        content_length = stat.size

        # Added Range Query support
        if range = request.header["range"].first
          response.status = 206
          if range =~ /bytes=(\d*)-(\d*)/
            start = $1.to_i
            finish = $2.to_i
            finish_str = ""
            if finish == 0
              finish = content_length - 1
              finish_str = "#{finish}"
            else
              finish_str = finish.to_s
            end

            bytes_to_read = finish - start + 1
            response['Content-Range'] = "bytes #{start}-#{finish_str}/#{content_length}"
            real_obj.io.pos = start
            response.body = real_obj.io.read(bytes_to_read)
            return
          end
        end
        response['Content-Length'] = File::Stat.new(real_obj.io.path).size
        response['Last-Modified'] = real_obj.modified_date
        if s_req.http_verb == 'HEAD'
          response.body = ""
        else
          response.body = real_obj.io
        end
      end
    end

    def do_PUT(request,response)
      add_cors_headers(request, response)
      s_req = normalize_request(request)

      case s_req.type
      when Request::COPY
        @store.copy_object(s_req.src_bucket,s_req.src_object,s_req.bucket,s_req.object)
      when Request::STORE
        bucket_obj = get_bucket(s_req.bucket)
        real_obj = @store.store_object(bucket_obj,s_req.object,s_req.webrick_request)
        response['Etag'] = "\"#{real_obj.md5}\""
      when Request::CREATE_BUCKET
        @store.create_bucket(s_req.bucket)
      end

      response.status = 200
      response.body = ""
      response['Content-Type'] = "text/xml"
    end

    # See:
    # http://aws.amazon.com/articles/1434
    # http://docs.aws.amazon.com/AmazonS3/latest/dev/HTTPPOSTForms.html
    # http://docs.aws.amazon.com/AmazonS3/2006-03-01/API/RESTObjectPOST.html
    def do_POST(request,response)
      add_cors_headers(request, response)

      s_req = normalize_request(request)
      bucket_obj = get_bucket(s_req.bucket)
      real_obj = @store.store_object(bucket_obj, s_req.object, s_req.webrick_request)
      response['Etag'] = "\"#{real_obj.md5}\""
      response['Connection'] = 'close'

      form = request.query
      if redirect = form['success_action_redirect']
        response.status = 307
        response['Location'] = redirect
      else
        status = form['success_action_status']
        response.status = status ? status.to_i : 204
        if response.status == 201
          response.body = <<-EOS
          <?xml version="1.0" encoding="UTF-8"?>
          <PostResponse>
            <Location>http://#{request.host}:#{request.port}/#{s_req.object}</Location>
            <Bucket>#{s_req.bucket}</Bucket>
            <Key>#{s_req.object}</Key>
            <ETag>#{real_obj.md5}</ETag>
          </PostResponse>
          EOS
        end
      end
    rescue => e
      response.status = 400
      response.body = e.message
    end

    def do_DELETE(request,response)
      add_cors_headers(request, response)
      s_req = normalize_request(request)

      case s_req.type
      when Request::DELETE_OBJECT
        bucket_obj = @store.get_bucket(s_req.bucket)
        @store.delete_object(bucket_obj,s_req.object,s_req.webrick_request)
      when Request::DELETE_BUCKET
        @store.delete_bucket(s_req.bucket)
      end

      response.status = 204
      response.body = ""
    end

    private
    def add_cors_headers(request, response)
      response['Access-Control-Allow-Origin'] = '*' if request['Origin']
    end

    def get_bucket(bucket)
      unless bucket_obj = @store.get_bucket(bucket)
        # Lazily create a bucket.  TODO fix this to return the proper error
        bucket_obj = @store.create_bucket(bucket)
      end
      bucket_obj
    end

    def normalize_delete(webrick_req,s_req)
      path = webrick_req.path
      path_len = path.size
      query = webrick_req.query
      if path == "/" and s_req.is_path_style
        # Probably do a 404 here
      else
        if s_req.is_path_style
          elems = path[1,path_len].split("/")
          s_req.bucket = elems[0]
        else
          elems = path.split("/")
        end

        if elems.size == 0
          raise UnsupportedOperation
        elsif elems.size == 1
          s_req.type = Request::DELETE_BUCKET
          s_req.query = query
        else
          s_req.type = Request::DELETE_OBJECT
          object = elems[1,elems.size].join('/')
          s_req.object = object
        end
      end
    end

    def normalize_get(webrick_req,s_req)
      path = webrick_req.path
      path_len = path.size
      query = webrick_req.query
      if path == "/" and s_req.is_path_style
        s_req.type = Request::LIST_BUCKETS
      else
        if s_req.is_path_style
          elems = path[1,path_len].split("/")
          s_req.bucket = elems[0]
        else
          elems = path.split("/")
        end

        if elems.size == 0
          # List buckets
          s_req.type = Request::LIST_BUCKETS
        elsif elems.size == 1
          s_req.type = Request::LS_BUCKET
          s_req.query = query
        else
          if query["acl"] == ""
            s_req.type = Request::GET_ACL
          else
            s_req.type = Request::GET
          end
          object = elems[1,elems.size].join('/')
          s_req.object = object
        end
      end
    end

    def normalize_put(webrick_req,s_req)
      path = webrick_req.path
      path_len = path.size
      if path == "/"
        if s_req.bucket
          s_req.type = Request::CREATE_BUCKET
        end
      else
        if s_req.is_path_style
          elems = path[1,path_len].split("/")
          s_req.bucket = elems[0]
          if elems.size == 1
            s_req.type = Request::CREATE_BUCKET
          else
            if webrick_req.request_line =~ /\?acl/
              s_req.type = Request::SET_ACL
            else
              s_req.type = Request::STORE
            end
            s_req.object = elems[1,elems.size].join('/')
          end
        else
          if webrick_req.request_line =~ /\?acl/
            s_req.type = Request::SET_ACL
          else
            s_req.type = Request::STORE
          end
          s_req.object = webrick_req.path
        end
      end

      copy_source = webrick_req.header["x-amz-copy-source"]
      if copy_source and copy_source.size == 1
        src_elems = copy_source.first.split("/")
        root_offset = src_elems[0] == "" ? 1 : 0
        s_req.src_bucket = src_elems[root_offset]
        s_req.src_object = src_elems[1 + root_offset,src_elems.size].join("/")
        s_req.type = Request::COPY
      end

      s_req.webrick_request = webrick_req
    end

    def normalize_post(webrick_req, s_req)
      form = webrick_req.query
      file = form['file']
      s_req.object = form['key'].sub('${filename}', file.filename)
      headers = {'content-type' => [file['content-type']]}
      s_req.webrick_request = PostRequest.new(headers, file)
      s_req.type = Request::STORE
    end

    # This method takes a webrick request and generates a normalized FakeS3 request
    def normalize_request(webrick_req)
      host_header= webrick_req["Host"]
      host = host_header.split(':')[0]

      s_req = Request.new
      s_req.path = webrick_req.path
      s_req.is_path_style = true

      if !@root_hostnames.include?(host)
        s_req.bucket = host.split(".")[0]
        s_req.is_path_style = false
      end

      s_req.http_verb = webrick_req.request_method

      case webrick_req.request_method
      when 'PUT'
        normalize_put(webrick_req,s_req)
      when 'GET','HEAD'
        normalize_get(webrick_req,s_req)
      when 'DELETE'
        normalize_delete(webrick_req,s_req)
      when 'POST'
        normalize_post(webrick_req, s_req)
      else
        raise "Unknown Request"
      end

      return s_req
    end

    def dump_request(request)
      puts "----------Dump Request-------------"
      puts request.request_method
      puts request.path
      request.each do |k,v|
        puts "#{k}:#{v}"
      end
      puts "----------End Dump -------------"
    end
  end


  class Server
    def initialize(address,port,store,hostname,silent=false)
      @address = address
      @port = port
      @store = store
      @hostname = hostname
      @silent = silent
    end

    def serve
      options = {
        :BindAddress => @address,
        :Port => @port
      }
      options.merge!(
        :AccessLog => [],
        :Logger => WEBrick::Log::new("/dev/null", 7)
      ) if @silent

      @server = WEBrick::HTTPServer.new(options)
      @server.mount "/", Servlet, @store,@hostname
      trap "INT" do @server.shutdown end
      @server.start
    end

    def shutdown
      @server.shutdown
    end
  end
end
