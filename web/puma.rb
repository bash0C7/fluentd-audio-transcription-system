port ENV.fetch('PORT', 9292)
threads 4, 8
environment ENV.fetch('RACK_ENV', 'development')
plugin :tmp_restart
