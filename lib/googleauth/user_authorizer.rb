# Copyright 2014, Google Inc.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are
# met:
#
#     * Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above
# copyright notice, this list of conditions and the following disclaimer
# in the documentation and/or other materials provided with the
# distribution.
#     * Neither the name of Google Inc. nor the names of its
# contributors may be used to endorse or promote products derived from
# this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
# OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
# SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
# LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
# DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
# THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

require 'uri'
require 'multi_json'
require 'googleauth/signet'
require 'googleauth/user_refresh'

module Google
  module Auth
    # Handles an interactive 3-Legged-OAuth2 (3LO) user consent authorization.
    #
    # Example usage for a simple command line app:
    #
    #     credentials = authorizer.get_credentials(user_id)
    #     if credentials.nil?
    #       url = authorizer.get_redirect_uri(user_id,
    #                                         nil,
    #                                         'urn:ietf:wg:oauth:2.0:oob')
    #       puts "Open the following URL in the browser and enter the " +
    #            "resulting code after authorization"
    #       puts url
    #       code = gets
    #       creds = authorizer.get_and_store_credentials_from_code(user_id,
    #                                                              code)
    #     end
    #     # Credentials ready to use, call APIs
    #     ...
    class UserAuthorizer
      MISMATCHED_CLIENT_ID_ERROR =
        'Token client ID of %s does not match configured client id %s'
      NIL_CLIENT_ID_ERROR = 'Client id can not be nil.'
      NIL_SCOPE_ERROR = 'Scope can not be nil.'
      NIL_USER_ID_ERROR = 'User ID can not be nil.'
      NIL_TOKEN_STORE_ERROR = 'Can not call method if token store is nil'
      MISSING_ABSOLUTE_URL_ERROR =
        'Absolute base url required for relative callback url "%s"'

      # Initialize the authorizer
      #
      # @param [Google::Auth::ClientID] client_id
      #  Configured ID & secret for this application
      # @param [String, Array<String>] scope
      #  Authorization scope to request
      # @param [Google::Auth::Stores::TokenStore] token_store
      #  Backing storage for persisting user credentials
      # @param [String] callback_uri
      #  URL (either absolute or relative) of the auth callback.
      #  Defaults to '/oauth2callback'
      def initialize(client_id, scope, token_store, callback_uri = nil)
        fail NIL_CLIENT_ID_ERROR if client_id.nil?
        fail NIL_SCOPE_ERROR if scope.nil?

        @client_id = client_id
        @scope = Array(scope)
        @token_store = token_store
        @callback_uri = callback_uri || '/oauth2callback'
      end

      # Build the URL for requesting authorization.
      #
      # @param [String] login_hint
      #  Login hint if need to authorize a specific account. Should be a
      #  user's email address or unique profile ID.
      # @param [String] state
      #  Opaque state value to be returned to the oauth callback.
      # @param [String] base_url
      #  Absolute URL to resolve the configured callback uri against. Required
      #  if the configured callback uri is a relative.
      # @param [String, Array<String>] scope
      #  Authorization scope to request. Overrides the instance scopes if not
      #  nil.
      # @return [String]
      #  Authorization url
      def get_authorization_url(options = {})
        scope = options[:scope] || @scope
        credentials = UserRefreshCredentials.new(
          client_id: @client_id.id,
          client_secret: @client_id.secret,
          scope: scope)
        redirect_uri = redirect_uri_for(options[:base_url])
        url = credentials.authorization_uri(access_type: 'offline',
                                            redirect_uri: redirect_uri,
                                            approval_prompt: 'force',
                                            state: options[:state],
                                            include_granted_scopes: true,
                                            login_hint: options[:login_hint])
        url.to_s
      end

      # Fetch stored credentials for the user.
      #
      # @param [String] user_id
      #  Unique ID of the user for loading/storing credentials.
      # @param [Array<String>, String] scope
      #  If specified, only returns credentials that have all
      #  the requested scopes
      # @return [Google::Auth::UserRefreshCredentials]
      #  Stored credentials, nil if none present
      def get_credentials(user_id, scope = nil)
        fail NIL_USER_ID_ERROR if user_id.nil?
        fail NIL_TOKEN_STORE_ERROR if @token_store.nil?

        scope ||= @scope
        saved_token = @token_store.load(user_id)
        return nil if saved_token.nil?
        data = MultiJson.load(saved_token)

        if data.fetch('client_id', @client_id.id) != @client_id.id
          fail sprintf(MISMATCHED_CLIENT_ID_ERROR,
                       data['client_id'], @client_id.id)
        end

        credentials = UserRefreshCredentials.new(
          client_id: @client_id.id,
          client_secret: @client_id.secret,
          scope: data['scope'] || @scope,
          access_token: data['access_token'],
          refresh_token: data['refresh_token'],
          expires_at: data.fetch('expiration_time_millis', 0) / 1000)
        if credentials.includes_scope?(scope)
          monitor_credentials(user_id, credentials)
          return credentials
        end
        nil
      end

      # Exchanges an authorization code returned in the oauth callback
      #
      # @param [String] user_id
      #  Unique ID of the user for loading/storing credentials.
      # @param [String] code
      #  The authorization code from the OAuth callback
      # @param [String, Array<String>] scope
      #  Authorization scope requested. Overrides the instance
      #  scopes if not nil.
      # @param [String] base_url
      #  Absolute URL to resolve the configured callback uri against.
      #  Required if the configured
      #  callback uri is a relative.
      # @return [Google::Auth::UserRefreshCredentials]
      #  Credentials if exchange is successful
      def get_credentials_from_code(options = {})
        user_id = options[:user_id]
        code = options[:code]
        scope = options[:scope] || @scope
        base_url = options[:base_url]
        credentials = UserRefreshCredentials.new(
          client_id: @client_id.id,
          client_secret: @client_id.secret,
          redirect_uri: redirect_uri_for(base_url),
          scope: scope)
        credentials.code = code
        credentials.fetch_access_token!({})
        monitor_credentials(user_id, credentials)
      end

      # Exchanges an authorization code returned in the oauth callback.
      # Additionally, stores the resulting credentials in the token store if
      # the exchange is successful.
      #
      # @param [String] user_id
      #  Unique ID of the user for loading/storing credentials.
      # @param [String] code
      #  The authorization code from the OAuth callback
      # @param [String, Array<String>] scope
      #  Authorization scope requested. Overrides the instance
      #  scopes if not nil.
      # @param [String] base_url
      #  Absolute URL to resolve the configured callback uri against.
      #  Required if the configured
      #  callback uri is a relative.
      # @return [Google::Auth::UserRefreshCredentials]
      #  Credentials if exchange is successful
      def get_and_store_credentials_from_code(options = {})
        credentials = get_credentials_from_code(options)
        monitor_credentials(options[:user_id], credentials)
        store_credentials(options[:user_id], credentials)
      end

      # Revokes a user's credentials. This both revokes the actual
      # grant as well as removes the token from the token store.
      #
      # @param [String] user_id
      #  Unique ID of the user for loading/storing credentials.
      def revoke_authorization(user_id)
        credentials = get_credentials(user_id)
        if credentials
          begin
            @token_store.delete(user_id)
          ensure
            credentials.revoke!
          end
        end
        nil
      end

      # Store credentials for a user. Generally not required to be
      # called directly, but may be used to migrate tokens from one
      # store to another.
      #
      # @param [String] user_id
      #  Unique ID of the user for loading/storing credentials.
      # @param [Google::Auth::UserRefreshCredentials] credentials
      #  Credentials to store.
      def store_credentials(user_id, credentials)
        json = MultiJson.dump(
          client_id: credentials.client_id,
          access_token: credentials.access_token,
          refresh_token: credentials.refresh_token,
          scope: credentials.scope,
          expiration_time_millis: (credentials.expires_at.to_i) * 1000)
        @token_store.store(user_id, json)
        credentials
      end

      private

      # Begin watching a credential for refreshes so the access token can be
      # saved.
      #
      # @param [String] user_id
      #  Unique ID of the user for loading/storing credentials.
      # @param [Google::Auth::UserRefreshCredentials] credentials
      #  Credentials to store.
      def monitor_credentials(user_id, credentials)
        credentials.on_refresh do |cred|
          store_credentials(user_id, cred)
        end
        credentials
      end

      # Resolve the redirect uri against a base.
      #
      # @param [String] base_url
      #  Absolute URL to resolve the callback against if necessary.
      # @return [String]
      #  Redirect URI
      def redirect_uri_for(base_url)
        return @callback_uri unless URI(@callback_uri).scheme.nil?
        fail sprintf(
          MISSING_ABSOLUTE_URL_ERROR,
          @callback_uri) if base_url.nil? || URI(base_url).scheme.nil?
        URI.join(base_url, @callback_uri).to_s
      end
    end
  end
end
