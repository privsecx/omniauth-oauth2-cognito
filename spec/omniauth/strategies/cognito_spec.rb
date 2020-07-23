# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OmniAuth::Strategies::Cognito do
  subject { strategy }

  let(:strategy) { described_class.new(app, client_id, client_secret, options) }

  let(:app) { ->(_env) { [200, '', {}] } }
  let(:callback_url) { 'http://localhost/auth/cognito/callback?code=1234' } # TODO: tests for this
  let(:client_id) { 'ABCDE' }
  let(:client_secret) { '987654321' }
  let(:options) { {} }
  let(:oauth_client) { double('OAuth2::Client', auth_code: auth_code) }
  let(:session) { { 'omniauth.state' => 'some_state' } }

  around do |example|
    OmniAuth.config.test_mode = true

    example.run

    OmniAuth.config.test_mode = false
  end

  it_behaves_like 'an oauth2 strategy'

  context 'methods' do
    let(:access_token_object) { double('OAuth2::AccessToken') }
    let(:auth_code) { double('OAuth2::AuthCode', get_token: access_token_object) }
    let(:params) { { 'code' => '12345' } }
    let(:request) { double('Rack::Request', params: params) }

    subject do
      described_class.new(client_id, client_secret, options).tap do |strategy|
        allow(strategy).to receive(:client).and_return(oauth_client)
        allow(strategy).to receive(:request).and_return(request)
      end
    end

    describe '#build_access_token' do
      before do
        allow(subject).to receive(:callback_url).and_return(callback_url)
      end

      it 'does not send the query part of the request URL as callback URL' do
        expect(auth_code).to receive(:get_token).with(
          params['code'],
          { redirect_uri: callback_url }.merge(subject.token_params.to_hash(symbolize_keys: true)),
          subject.__send__(:deep_symbolize, subject.options.auth_token_params)
        ).and_return(access_token_object)

        expect(subject.__send__(:build_access_token)).to eql access_token_object
      end
    end

    describe '#callback_url' do
      before do
        allow(subject).to receive(:full_host).and_return('http://localhost:3000')
        allow(subject).to receive(:script_name).and_return('')
      end

      it 'concatenates the callback_path and the full_host, without query string' do
        expect(subject.send(:callback_url)).to eq 'http://localhost:3000/auth/cognito/callback'
      end

      context 'with callback_path option' do
        let(:options) { { callback_path: '/some/callback/path' } }

        it 'uses custom callback_path' do
          expect(subject.send(:callback_url)).to eq 'http://localhost:3000/some/callback/path'
        end
      end
    end
  end

  describe 'auth hash' do
    let(:options) { { aws_region: 'eu-west-1', user_pool_id: 'user_pool_id' } }
    let(:auth_hash) { env['omniauth.auth'] }
    let(:env) { {} }
    let(:request) { double('Rack::Request', params: { 'state' => strategy.session['omniauth.state'] }) }
    let(:auth_code) { double('OAuth2::AuthCode') }
    let(:access_token_object) { OAuth2::AccessToken.from_hash(oauth_client, token_hash) }

    let(:token_hash) do
      {
        'expires_at' => token_expires.to_i,
        'access_token' => access_token_string,
        'refresh_token' => refresh_token_string,
        'id_token' => id_token_string
      }
    end

    let(:now) { Time.now }
    let(:token_expires) { now + 3600 }
    let(:access_token_string) { 'access_token' }
    let(:refresh_token_string) { 'refresh_token' }

    let(:id_sub) { '1234-5678-9012' }
    let(:id_phone) { 'some phone number' }
    let(:id_email) { 'some email address' }
    let(:id_name) { 'Some Name' }

    let(:id_token_string) do
      JWT.encode(
        {
          sub: id_sub,
          iat: now.to_i,
          iss: 'https://cognito.eu-west-1.amazonaws.com/user_pool_id',
          nbf: now.to_i,
          exp: token_expires.to_i,
          aud: strategy.options[:client_id],
          phone_number: id_phone,
          email: id_email,
          name: id_name
        },
        '12345'
      )
    end

    let(:callback_url) { 'http://localhost/auth/cognito/callback?code=1234' }

    before do
      allow(strategy).to receive(:env).and_return(env)
      allow(strategy).to receive(:session).and_return(session)
      allow(strategy).to receive(:request).and_return(request)
      allow(strategy).to receive(:callback_url).and_return(callback_url)
      allow(strategy).to receive(:client).and_return(oauth_client)

      allow(auth_code).to receive(:get_token).and_return(access_token_object)

      strategy.callback_phase
    end

    describe ':uid' do
      it 'includes the `sub` claim from the ID token' do
        expect(auth_hash[:uid]).to eql id_sub
      end
    end

    describe ':info' do
      it 'includes email by default' do
        expect(auth_hash[:info]).to eql('email' => id_email)
      end

      context 'with info_fields option' do
        let(:options) { { info_fields: %i[name email phone_number] } }

        it 'adds additional fields' do
          expect(auth_hash[:info]).to eql('name' => id_name, 'email' => id_email, 'phone_number' => id_phone)
        end
      end
    end

    describe ':credentials' do
      it 'contains all tokens' do
        expect(auth_hash[:credentials]).to eql(
          'expires' => true,
          'expires_at' => token_expires.to_i,
          'id_token' => id_token_string,
          'refresh_token' => refresh_token_string,
          'token' => access_token_string
        )
      end
    end

    describe ':extra' do
      it 'contains the parsed data from the id token' do
        expect(auth_hash[:extra]).to eq(
          'raw_info' => {
            'sub' => id_sub,
            'phone_number' => id_phone,
            'email' => id_email,
            'name' => id_name,
            'iss' => 'https://cognito.eu-west-1.amazonaws.com/user_pool_id',
            'aud' => strategy.options[:client_id],
            'exp' => token_expires.to_i,
            'iat' => now.to_i,
            'nbf' => now.to_i
          }
        )
      end
    end
  end

  describe 'JWT decoding' do
    let(:options) { { aws_region: 'eu-west-1', user_pool_id: 'user_pool_id',
      jwt_verify: true, jwt_key: cognito_verification_key, algorithm: 'RS256'  } }
    let(:auth_hash) { env['omniauth.auth'] }
    let(:env) { {} }
    let(:request) { double('Rack::Request', params: { 'state' => strategy.session['omniauth.state'] }) }
    let(:auth_code) { double('OAuth2::AuthCode') }
    let(:access_token_object) { OAuth2::AccessToken.from_hash(oauth_client, token_hash) }

    let(:token_hash) do
      {
        'expires_at' => token_expires.to_i,
        'access_token' => access_token_string,
        'refresh_token' => refresh_token_string,
        'id_token' => id_token_string
      }
    end

    let(:now) { Time.now }
    let(:token_expires) { now + 3600 }
    let(:access_token_string) { 'access_token' }
    let(:refresh_token_string) { 'refresh_token' }

    let(:id_sub) { '1234-5678-9012' }
    let(:id_phone) { 'some phone number' }
    let(:id_email) { 'some email address' }
    let(:id_name) { 'Some Name' }


    let(:callback_url) { 'http://localhost/auth/cognito/callback?code=1234' }
    let(:cognito_signing_key) { OpenSSL::PKey::RSA.generate 2048 }

    before do
      allow(strategy).to receive(:env).and_return(env)
      allow(strategy).to receive(:session).and_return(session)
      allow(strategy).to receive(:request).and_return(request)
      allow(strategy).to receive(:callback_url).and_return(callback_url)
      allow(strategy).to receive(:client).and_return(oauth_client)

      allow(auth_code).to receive(:get_token).and_return(access_token_object)

      strategy.callback_phase
    end

    context "with the verification key corresponding to the signing key" do
      let(:cognito_verification_key) { cognito_signing_key.public_key }

      let(:id_token_string) do
        JWT.encode(
          {
            sub: id_sub,
            iat: now.to_i,
            iss: 'https://cognito-idp.eu-west-1.amazonaws.com/user_pool_id',
            nbf: now.to_i,
            exp: token_expires.to_i,
            aud: strategy.options[:client_id],
            phone_number: id_phone,
            email: id_email,
            name: id_name
          },
          cognito_signing_key,
          'RS256'
        )
      end

      describe ':uid' do
        it 'includes the `sub` claim from the ID token' do
          expect(auth_hash[:uid]).to eql id_sub
        end
      end

      describe ':info' do
        it 'includes email by default' do
          expect(auth_hash[:info]).to eql('email' => id_email)
        end

        context 'with info_fields option' do
          let(:options) { { info_fields: %i[name email phone_number] } }

          it 'adds additional fields' do
            expect(auth_hash[:info]).to eql('name' => id_name, 'email' => id_email, 'phone_number' => id_phone)
          end
        end
      end

      describe ':credentials' do
        it 'contains all tokens' do
          expect(auth_hash[:credentials]).to eql(
            'expires' => true,
            'expires_at' => token_expires.to_i,
            'id_token' => id_token_string,
            'refresh_token' => refresh_token_string,
            'token' => access_token_string
          )
        end
      end

      describe ':extra' do
        it 'contains the parsed data from the id token' do
          expect(auth_hash[:extra]).to eq(
            'raw_info' => {
              'sub' => id_sub,
              'phone_number' => id_phone,
              'email' => id_email,
              'name' => id_name,
              'iss' => 'https://cognito-idp.eu-west-1.amazonaws.com/user_pool_id',
              'aud' => strategy.options[:client_id],
              'exp' => token_expires.to_i,
              'iat' => now.to_i,
              'nbf' => now.to_i
            }
          )
        end
      end
    end

    context "with a BAD verification key" do
      let(:attacker_signing_key) { OpenSSL::PKey::RSA.generate 2048 } # new attacker key!
      let(:cognito_verification_key) { cognito_signing_key.public_key }
      let(:id_token_string) do
        JWT.encode(
          {
            sub: id_sub,
            iat: now.to_i,
            iss: 'https://cognito-idp.eu-west-1.amazonaws.com/user_pool_id',
            nbf: now.to_i,
            exp: token_expires.to_i,
            aud: strategy.options[:client_id],
            phone_number: id_phone,
            email: id_email,
            name: id_name
          },
          attacker_signing_key,
          'RS256'
        )
      end


      describe ':uid' do
        it 'includes the `sub` claim from the ID token' do
          expect(auth_hash[:uid]).to eql id_sub
        end
      end

      describe ':info' do
        it 'includes email by default' do
          expect(auth_hash[:info]).to eql('email' => id_email)
        end

        context 'with info_fields option' do
          let(:options) { { info_fields: %i[name email phone_number] } }

          it 'adds additional fields' do
            expect(auth_hash[:info]).to eql('name' => id_name, 'email' => id_email, 'phone_number' => id_phone)
          end
        end
      end

      describe ':credentials' do
        it 'contains all tokens' do
          expect(auth_hash[:credentials]).to eql(
            'expires' => true,
            'expires_at' => token_expires.to_i,
            'id_token' => id_token_string,
            'refresh_token' => refresh_token_string,
            'token' => access_token_string
          )
        end
      end

      describe ':extra' do
        it 'contains the parsed data from the id token' do
          expect(auth_hash[:extra]).to eq(
            'raw_info' => {
              'sub' => id_sub,
              'phone_number' => id_phone,
              'email' => id_email,
              'name' => id_name,
              'iss' => 'https://cognito-idp.eu-west-1.amazonaws.com/user_pool_id',
              'aud' => strategy.options[:client_id],
              'exp' => token_expires.to_i,
              'iat' => now.to_i,
              'nbf' => now.to_i
            }
          )
        end
      end
    end
  end
end
