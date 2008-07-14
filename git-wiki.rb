#!/usr/bin/env ruby
%w(rubygems sinatra haml sass git redcloth captcha).each do |dependency|
  begin
    $: << File.expand_path(File.dirname(__FILE__) + "/vendor/#{dependency}/lib")
    require dependency
  rescue LoadError
    abort "Unable to load #{dependency}. Did you run 'git submodule init' ? If so install #{dependency}"
  end
end

class Page
  class << self
    attr_accessor :repo
  end

  def self.find_all
    return [] if (Page.repo.log.size rescue 0) == 0
    Page.repo.log.first.gtree.children.map { |name, blob| Page.new(name) }.sort_by { |p| p.name }
  end

  attr_reader :name
  attr_writer :raw_text

  def initialize(name)
    @name = name
    @filename = File.join(GitRepository, @name)
    @changed = false
  end

  def html
    text = raw_text.gsub(/(?:\[\[([A-Za-z0-9]+)\]\]|([A-Z][a-z]+[A-Z][A-Za-z0-9]+))/) do |match|
      page = $1 || $2
      "<a class='#{Page.new(page).tracked? ? 'exists' : 'unknown'}' href='#{page}'>#{page}</a>"
    end
    RedCloth.new(text).to_html
  end

  def original_raw_text
    @original_raw_text ||= File.exists?(@filename) ? File.read(@filename) : ''
  end

  def raw_text
    @raw_text || original_raw_text 
  end

  def save
    return if raw_text == original_raw_text
    File.open(@filename, 'w') { |f| f << raw_text }
    message = tracked? ? "Edited #{@name}" : "Created #{@name}"
    Page.repo.add(@name)
    Page.repo.commit(message)
  end

  def tracked?
    Page.repo.ls_files.keys.include?(@name)
  end

  def to_s
    @name
  end
end

use_in_file_templates!

configure do
  GitRepository = ENV['GIT_WIKI_REPOSITORY'] || File.join(ENV['HOME'], 'wiki')
  Homepage = 'Home'
  set_option :haml, :format => :html4

  unless (Page.repo = Git.open(GitRepository) rescue false)
    abort "#{GitRepository}: Not a git repository. Install your wiki with `rake bootstrap`"
  end
end

helpers do
  def title(title=nil)
    @title = title unless title.nil?
    @title
  end

  def list_item(page)
    "<a class='page_name' href='/#{page}'>#{page}</a>&nbsp;<a class='edit' href='/e/#{page}'>edit</a>"
  end
end

before do
  content_type 'text/html', :charset => 'utf-8'
end

get('/') { redirect '/' + Homepage }

get('/_stylesheet.css') do
  content_type 'text/css', :charset => 'utf-8'
  sass :stylesheet
end

get '/_list' do
  @pages = Page.find_all
  haml :list
end

get '/:page' do
  @page = Page.new(params[:page])
  @page.tracked? ? haml(:show) : redirect("/e/#{@page.name}")
end

# Waiting for Black's new awesome route system
get '/:page.txt' do
  @page = Page.new(params[:page])
  throw :halt, [404, "Unknown page #{params[:page]}"] unless @page.tracked?
  content_type 'text/plain', :charset => 'utf-8'
  @page.raw_text
end

get '/e/:page' do
  @page = Page.new(params[:page])
  @captcha = CAPTCHA::Web.from_configuration( File.join(File.dirname(__FILE__), "captcha/captcha.conf") )
  @captcha.clean
  haml :edit
end

post '/e/:page' do
  @page = Page.new(params[:page])
  @page.raw_text = params[:raw_text]
  if CAPTCHA::Web.is_valid(params[:key], params[:digest])
    @page.save
    request.xhr? ? @page.html : redirect("/#{@page.name}")
  else
    @captcha = CAPTCHA::Web.from_configuration( File.join(File.dirname(__FILE__), "captcha/captcha.conf") )
    @captcha.clean
    @bad_captcha = true 
    haml :edit
  end
end

__END__
@@ layout
!!! strict
%html
  %head
    %title= title
    %link{:rel => 'stylesheet', :href => '/_stylesheet.css', :type => 'text/css'}
    %script{:src => '/jquery-1.2.3.min.js', :type => 'text/javascript'}
    %script{:src => '/jquery.jeditable.js', :type => 'text/javascript'}
    %script{:src => '/jquery.autogrow.js', :type => 'text/javascript'}
    %script{:src => '/jquery.hotkeys.js', :type => 'text/javascript'}
    :javascript
      $(document).ready(function() {
        $.hotkeys.add('Ctrl+h', function() { document.location = '/#{Homepage}' })
        $.hotkeys.add('Ctrl+l', function() { document.location = '/_list' })
      })
  %body
    .doc
      #header
        .logo 
          %img{:src => '/helmet.png'}
        .title 
          %a{:href => '/'} Viking's wiki
        %ul#navigation
          %li
            %a{:href => '/'} Home
          %li
            %a{:href => '/_list'} List
      #content
        - if @notice
          %p#notice= @notice
          :javascript
            $('#notice').fadeOut(3000)
        = yield

@@ show
- title @page.name
%a#edit_link{:href => "/e/#{@page}"} Edit this page
%h1.title= title
#page_content
  ~"#{@page.html}"

@@ edit
- title "Editing #{@page}"

%h1.title= title
%form{:method => 'POST', :action => "/e/#{@page}"}
  %p
    %textarea{:name => 'raw_text', :rows => 16, :cols => 60}= @page.raw_text
  .captcha
    %p 
      Please enter the text from the image:<br/>
      %input{:type => 'text', :name => 'key', :value => "", :style => @bad_captcha ? "border: 2px solid red" : nil}
    %img{:src => "/images/#{@captcha.file_name}", :width => "#{@captcha.image.width}", :height => "#{@captcha.image.height}"}
  %p{:style => "clear: both; padding-top: 2em"}
    %input.submit{:type => :submit, :value => 'Save as the newest version'}
    or
    %a.cancel{:href=>"/#{@page}"} cancel
    %input{:type => 'hidden', :name => 'digest', :value => "#{@captcha.digest}"}  

@@ list
- title "Listing pages"

%h1.title All pages
- if @pages.empty?
%p No pages found.
- else
  %ul#pages_list
    - @pages.each_with_index do |page, index|
      - if (index % 2) == 1
        %li.odd= list_item(page)
      - else
        %li.even= list_item(page)
    - end

@@ stylesheet
body
  :font
    family: "Lucida Grande", Verdana, Arial, Bitstream Vera Sans, Helvetica, sans-serif
    size: 62.5%
    color: black
  line-height: 1.25 
  background-color: #ddd
  margin: 0
  padding: 0 70px 1em 0
  text-align: center

.doc
  margin: 0 auto
  min-width: 840px
  width: 840px
  text-align: left

#header
  height: 39px
  margin-top: 5em
  position: relative
  .logo
    position: absolute
    left: -91px
    top: -50px
  .title
    position: absolute
    margin: 0 0 0 50px
    font:
      size: 28px
    a
      color: black
      &:hover
        text-decoration: none
        color: black
  #navigation
    position: absolute
    right: 0
    bottom: 7px
    margin: 0 10px 0 0
    font-size: 15px
    li
      list-style-type: none
      display: inline

#content
  padding: 1em 2em 2em 2em 
  background: white
  h1
    font-size: 2.4em
  .title
    margin:
      left: 50px
      bottom: 40px
    border-bottom: 1px solid #aaa
        
  #page_content,
  #pages_list
    font-size: 14px

#notice
  background-color: #ffc
  padding: 6px
  margin-left: 5em

a
  padding: 2px
  color: blue
  text-decoration: none
  &.exists
    &:hover
      background-color: blue
      text-decoration: none
      color: white
  &.unknown
    color: gray
    &:hover
      background-color: gray
      color: white
      text-decoration: none

textarea
  font-family: courrier
  padding: 5px
  font-size: 14px
  line-height: 18px

#edit_link
  background-color: #ffc
  font-weight: bold
  text-decoration: none
  color: black
  float: right
  &:hover
    color: white
    background-color: red

.submit
  font-weight: bold

.cancel
  color: red
  &:hover
    text-decoration: none
    background-color: red
    color: white

.captcha
  img
    float: left
  p
    float: left
    margin-right: 4em

ul#pages_list
  list-style-type: none
  margin: 0
  padding: 0
  li
    padding: 5px
    a.edit
      display: none 
    &.odd
      background-color: #e3e3e3
