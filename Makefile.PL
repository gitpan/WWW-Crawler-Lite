use strict;
use warnings;
use inc::Module::Install;
use 5.008005;

name 'WWW-Crawler-Lite';
perl_version '5.008005';
license 'perl';
all_from 'lib/WWW/Crawler/Lite.pm';

test_requires 'Test::More'  => 0;

requires  'HTML::LinkExtor'       => 3.60;
requires  'LWP::UserAgent'        => 5.834;
requires  'HTTP::Request::Common' => 5.824;
requires  'Time::HiRes'           => 0;

tests_recursive();
WriteAll();

