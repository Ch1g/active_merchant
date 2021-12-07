module ActiveMerchant #:nodoc:
  module Billing #:nodoc:
    class FluidPayGateway < Gateway
      self.test_url = 'https://sandbox.fluidpay.com'
      self.live_url = 'https://app.fluidpay.com'

      self.money_format = :cents

      self.homepage_url = 'https://www.fluidpay.com'
      self.display_name = 'FluidPay'

      RESPONSE_CODE_MAPPING = {
        0        => 'Unknown',
        99       => 'Pending payment',
        100      => 'Approved',
        110      => 'Partial approved',
        101      => 'Approved, pending customer approval',
        200      => 'Decline',
        201      => 'Do not honor',
        202      => 'Insufficient funds',
        203      => 'Exceeds withdrawn limit',
        204      => 'Invalid Transaction',
        205      => 'SCA Decline',
        220      => 'Invalid Amount',
        221      => 'No such Issuer',
        222      => 'No credit Acct',
        223      => 'Expired Card',
        225      => 'Invalid CVC',
        226      => 'Cannot Verify Pin',
        240      => 'Refer to issuer',
        250      => 'Pick up card (no fraud)',
        251      => 'Lost card, pick up (fraud account)',
        252      => 'Stolen card, pick up (fraud account)',
        253      => 'Pick up card, special condition',
        261      => 'Stop recurring',
        262      => 'Stop recurring',
        300      => 'Gateway Decline',
        301      => 'Gateway Decline - Duplicate Transaction',
        310      => 'Gateway Decline - Rule Engine',
        320      => 'Gateway Decline - Chargeback',
        321      => 'Gateway Decline - Stop Fraud',
        322      => 'Gateway Decline - Closed Contact',
        323      => 'Gateway Decline - Stop Recurring',
        400      => 'Transaction error returned by processor',
        410      => 'Invalid merchant configuration',
        421      => 'Communication error with processor',
        430      => 'Duplicate transaction at processor',
        440      => 'Processor Format error'
      }

      PAYMENT_TYPES = %i[sale authorize verification credit]

      def initialize(options = {})
        requires!(options, :authorization)
        @username, @password, @api_key = options[:authorization].values_at(:username, :password, :api_key)
        super
      end

      def purchase(options = {})
        requires!(options, :payment_method)

        post = {}
        add_payment_method(post, options)
        add_address(post, options)
        add_additional_data(post, options)

        commit('transaction', post)
      end

      private

      AVS_MAPPING = {
        '0'  => 'R',  # AVS Not Available
        'A'  => 'A',  # Address match only
        'B'  => 'B',  # Address matches, ZIP not verified
        'C'  => 'E',  # Incompatible format
        'D'  => 'J',  # Great success
        'F'  => 'J',  # Exact match, UK-issued cards
        'G'  => 'G',  # Non-U.S. Issuer does not participate
        'I'  => 'I',  # Not verified
        'M'  => 'J',  # Exact match
        'N'  => 'N',  # No address or ZIP match	
        'P'  => 'P',  # Postal Code match
        'R'  => 'R',  # Issuer system unavailable
        'S'  => 'S',  # Service not supported
        'U'  => 'U',  # Address unavailable
        'W'  => 'W',  # 9-character numeric ZIP match only
        'X'  => 'X',  # Exact match, 9-character numeric ZIP
        'Y'  => 'Y',  # Exact match, 5-character numeric ZIP
        'Z'  => 'Z',  # 5-character ZIP match only
        '1'  => 'L',  # Cardholder name and ZIP match
        '2'  => 'J',  # Cardholder name, address and ZIP match
        '3'  => 'O',  # Cardholder name and address match
        '4'  => 'K',  # Cardholder name matches
        '5'  => 'F',  # Cardholder name incorrect, ZIP matches
        '6'  => 'H',  # Cardholder name incorrect, address and zip match
        '7'  => 'T',  # Cardholder name incorrect, address matches
        '8'  => 'N'   # Cardholder name, address, and ZIP do not match
      }

      def add_address(post, options)
        post[:billing_address] = options[:billing_address]
        post[:shipping_address] = options[:shipping_address]
        post
      end

      def add_payment_method(post, options)
        requires!(options, :payment_method)

        post[:payment_method] = {}

        if options[:payment_method].has_key?(:token)
          post[:payment_method][:token] = options[:payment_method][:token]
        end
        post
      end

      def add_additional_data(post, options)
        params = %i[type amount tax_amount shipping_amount currency description order_id po_number ip_address email_receipt email_address create_vault_record]
        params.each { |p| post[p] = options[p] }
        post
      end

      # request JWT
      def set_jwt_token
        return unless @username && @password

        post = { username: @username, password: @password }
        @jwt_token = commit('token-auth', post).params['data']['token']
      end

      def parse(body)
        return {} if body.blank?

        JSON.parse(body)
      end

      def commit(action, parameters)
        begin
          raw_response = ssl_post(url(action), post_data(action, parameters), request_headers(action))
          response = parse(raw_response)
        rescue ResponseError => e
          raw_response = e.response.body
          response = parse(raw_response)
        end

        success = success_from(action, response)
        Response.new(
          success,
          message_from(action, response),
          response,
          error_code: success ? nil : error_code_from(response),
          network_transaction_id: network_transaction_id_from(response),
          avs_result: AVSResult.new(code: avs_code_from(response)),
          cvv_result: CVVResult.new(cvv_result_from(response))
        )
      end

      def avs_code_from(response)
        AVS_MAPPING[response.dig('data', 'response_body', 'card', 'avs_response_code')]
      end

      def cvv_result_from(response)
        response.dig('data', 'response_body', 'card', 'cvv_response_code')
      end

      def error_code_from(response)
        RESPONSE_CODE_MAPPING[response['error_code']]
      end

      def url(action)
        if test?
          "#{test_url}/api/#{action}"
        else
          "#{live_url}/api/#{action}"
        end
      end

      def auth_header
        if @api_key
          @api_key
        elsif @username && @password
          set_jwt_token unless @jwt_token

          "Bearer { #{@jwt_token} }"
        end
      end

      def request_headers(action)
        headers = {
          'Content-Type' => 'application/json'
        }
        headers['Authorization'] = auth_header unless action == 'token-auth'
        headers
      end

      def success_from(action, response)
        case action
        when 'token-auth'
          response['status'] == 'successful'
        when 'transaction'
          response['data']['response'] == 'approved'
        else
          false
        end
      end

      def message_from(action, response)
        case action
        when 'transaction'
          RESPONSE_CODE_MAPPING[response['data']['response_code']]
        end
      end

      def network_transaction_id_from(response)
        response.dig('data', 'response_body', 'card', 'id')
      end

      def post_data(action, parameters = {})
        JSON.generate(parameters)
      end
    end
  end
end
