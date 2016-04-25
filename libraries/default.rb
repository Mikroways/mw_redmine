define_application_ruby 'redmine' do
  symlink_before_migrate %w(config/database.yml config/configuration.yml Gemfile.local)
  shared_directories %w(log tmp files plugins public/themes/custom)
  repository 'https://github.com/redmine/redmine.git'
  revision '3.1-stable'
  environment application_rails_environment
  migration_command <<-MIGRATE
    bundle exec rake db:migrate &&
    bundle exec rake redmine:plugins:migrate &&
    bundle exec rake generate_secret_token &&
    REDMINE_LANG=en bundle exec rake redmine:load_default_data
  MIGRATE

  class_helpers do
    attribute :secret_token, kind_of: String, required: true
    attribute :smtp_delivery_method, kind_of: Symbol, default: :async_smtp
    attribute :smtp_address, kind_of: String
    attribute :smtp_port, kind_of: Fixnum, default: 25
    attribute :smtp_authentication, kind_of: Symbol, default: :login
    attribute :smtp_domain, kind_of: String
    attribute :smtp_user_name, kind_of: String
    attribute :smtp_password, kind_of: String
    attribute :smtp_enable_starttls_auto, kind_of: [TrueClass, FalseClass], default: true
    attribute :db_name, kind_of: String, required: true, default: lazy { |resource| resource.name }
    attribute :db_user, kind_of: String, required: true, default: lazy { |resource| resource.name }
    attribute :db_password, kind_of: String
    attribute :db_host, kind_of: String, default: '127.0.0.1'
    attribute :db_adapter, kind_of: String, required: true
    attribute :gemfile_local_content, kind_of: String, default: 'gem "unicorn", "~> 5.0.0"'
  end

  helpers do
    def database_content
      {
        'production' => {
          'adapter'   => db_adapter,
          'database'  => db_name,
          'username'  => db_user,
          'password'  => db_password,
          'host'      => db_host,
          'pool'      => 5,
          'timeout'   => 5000
        }
      }.to_yaml
    end

    def configuration_content
      {
        'production' => {
          'secret_token' => secret_token,
          'email_delivery' => {
            'delivery_method' => smtp_delivery_method,
            "#{smtp_delivery_method.to_s}_settings" => {
              'address' => smtp_address,
              'port' => smtp_port,
              'authentication' => smtp_authentication,
              'domain' => smtp_domain,
              'user_name' => smtp_user_name,
              'password' => smtp_password,
              'enable_starttls_auto' => smtp_enable_starttls_auto,
            }
          }
        }
      }.to_yaml
    end
  end

  before_deploy do
    package new_resource
      .value_for_platform_family(debian: 'libmagickwand-dev',
                                 rhel: 'ImageMagick-devel')

    file "#{shared_path}/Gemfile.local" do
      owner application_resource.user
      content application_resource.gemfile_local_content
      notifies :force_deploy, "deploy[#{application_resource.name}]"
    end

    file "#{shared_path}/config/database.yml" do
      owner application_resource.user
      mode '0640'
      content application_resource.database_content
      sensitive true
    end

    file "#{shared_path}/config/configuration.yml" do
      owner application_resource.user
      content application_resource.configuration_content
    end
  end

  before_migrate do
    rbenv_script 'rbenv local' do
      cwd release_path
      rbenv_version application_resource.ruby
      code %(rbenv local #{application_resource.ruby})
    end

    # Must manually link database.yml so bundle installs required db driver
    file "#{release_path}/config/database.yml" do
      action :delete
    end

    link "#{release_path}/config/database.yml" do
      to "#{shared_path}/config/database.yml"
    end

    link "#{release_path}/Gemfile.local" do
      to "#{shared_path}/Gemfile.local"
    end

    # Only for the very first time. This means when there is
    # no Gemfile.lock created
    rbenv_script 'bundle install' do
      cwd release_path
      rbenv_version application_resource.ruby
      code %(bundle install --without development test)
      not_if "test -f #{release_path}/Gemfile.lock"
    end

    # Run when exists Gemfile.lock
    rbenv_script 'bundle update' do
      cwd release_path
      rbenv_version application_resource.ruby
      code %(bundle update)
      only_if "test -f #{release_path}/Gemfile.lock"
    end
  end
end
