#!/usr/bin/env ruby
%w(rubygems sinatra haml sass git redcloth captcha coderay).each do |dependency|
  begin
    $: << File.expand_path(File.dirname(__FILE__) + "/vendor/#{dependency}/lib")
    require dependency
  rescue LoadError
    abort "Unable to load #{dependency}. Did you run 'git submodule init' ? If so install #{dependency}"
  end
end

module Sinatra
  class Static
    # This is so I can set the content-type of extension-less cached pages
    def block
      Proc.new do
        path = request.path_info.http_unescape
        send_file Sinatra.application.options.public + path,
          :disposition => nil, :type => (path =~ %r{^/\w+$} ? 'text/html' : nil)
      end
    end
  end

  module Cache
    def cache(content)
      File.open(cache_path, 'w') { |f| f.puts content }
      content
    end

    def cache_path(page = nil)
      if page
        Sinatra.application.options.public + "/#{page}"
      else
        @cache_path ||= Sinatra.application.options.public + request.path_info.http_unescape
      end
    end
  end

  class EventContext
    include Cache
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
    pre = false
    text = raw_text.gsub(/(?:<\/?coderay>|\[\[([A-Za-z0-9]+)\]\]|(!?[A-Z][a-z]+[A-Z][A-Za-z0-9]+))/) do |match|
      result = case match
        when '<coderay>'
          pre = true
          match
        when '</coderay>'
          pre = false
          match
        else
          page = $1 || $2
          if pre
            match
          elsif page[0] == ?!
            page[1..-1]
          else
            "<a class='#{Page.new(page).tracked? ? 'exists' : 'unknown'}' href='#{page}'>#{page}</a>"
          end
      end
      result
    end
    text.gsub!(%r{<coderay>[\r\n]*(.+?)</coderay>}m) do |match|
      "<notextile>#{CodeRay.scan($1, :ruby).div}<br style='clear: both'/></notextile>"
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
    Page.repo.push
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
  Homepage      = 'Home'
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

get('/stylesheets/:sheet.css') do
  content_type 'text/css', :charset => 'utf-8'
  cache(sass(params[:sheet].to_sym))
end

get '/_list' do
  @pages = Page.find_all
  haml :list
end

get '/:page' do
  @page = Page.new(params[:page])
  if @page.tracked?
    # cache page
    cache(haml(:show))
  else
    redirect("/e/#{@page.name}")
  end
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
    if File.exist?(file = cache_path(@page.name))
      File.delete(file)
    end

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
    %link{:rel => 'stylesheet', :href => '/stylesheets/style.css', :type => 'text/css'}
    %link{:rel => 'stylesheet', :href => '/stylesheets/coderay.css', :type => 'text/css'}
    %script{:src => '/javascripts/jquery-1.2.3.min.js', :type => 'text/javascript'}
    %script{:src => '/javascripts/jquery.jeditable.js', :type => 'text/javascript'}
    %script{:src => '/javascripts/jquery.autogrow.js', :type => 'text/javascript'}
    %script{:src => '/javascripts/jquery.hotkeys.js', :type => 'text/javascript'}
    :javascript
      $(document).ready(function() {
        $.hotkeys.add('Ctrl+h', function() { document.location = '/#{Homepage}' })
        $.hotkeys.add('Ctrl+l', function() { document.location = '/_list' })
      })
  %body
    .doc
      #header
        .logo 
          %img{:src => '/images/helmet.png'}
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
    %img{:src => "/images/captchas/#{@captcha.file_name}", :width => "#{@captcha.image.width}", :height => "#{@captcha.image.height}"}
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

@@ style
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
    margin: 0 0 0 60px
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
  h1.title
    font-size: 2.4em
    margin:
      left: 45px
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

code
  color: #7A4707
  font:
    family: "Courier New", Courier, monospace
    size: 100%
    weight: bold
  line-height: 1.4em

@@ coderay
.CodeRay 
  background-color: #f8f8f8
  border: 1px solid silver
  font-family: 'Courier New', 'Terminal', monospace
  color: #100
  float: left
  pre 
    margin: 0px
  .code
    width: 100%
    padding: 1em
    pre
      overflow: auto
  .af
    color: #00C
  .an
    color: #007
  .av 
    color: #700
  .aw
    color: #C00
  .bi
    color: #509
    font-weight: bold
  .c
    color: #888
  .ch
    color: #04D
    .k
      color: #04D
    .dl
      color: #039
  .cl 
    color: #B06
    font-weight: bold 
  .co 
    color: #036
    font-weight: bold
  .cr 
    color: #0A0
  .cv 
    color: #369
  .df 
    color: #099
    font-weight: bold
  .di 
    color: #088
    font-weight: bold
  .dl 
    color: black
  .do 
    color: #970
  .ds 
    color: #D42
    font-weight: bold
  .e  
    color: #666
    font-weight: bold
  .en 
    color: #800
    font-weight: bold
  .er 
    color: #F00
    background-color: #FAA
  .ex 
    color: #F00
    font-weight: bold
  .fl 
    color: #60E
    font-weight: bold
  .fu 
    color: #06B
    font-weight: bold
  .gv 
    color: #d70
    font-weight: bold
  .hx 
    color: #058
    font-weight: bold
  .i  
    color: #00D
    font-weight: bold
  .ic 
    color: #B44
    font-weight: bold

  .il 
    background: #eee
    .il 
      background: #ddd
      .il 
        background: #ccc
    .idl 
      color: #888
      font-weight: bold

  .in 
    color: #B2B
    font-weight: bold
  .iv 
    color: #33B
  .la 
    color: #970
    font-weight: bold
  .lv 
    color: #963
  .oc 
    color: #40E
    font-weight: bold
  .on 
    color: #000
    font-weight: bold
  .op 
 
  .pc 
    color: #038
    font-weight: bold
  .pd 
    color: #369
    font-weight: bold
  .pp 
    color: #579
  .pt 
    color: #339
    font-weight: bold
  .r  
    color: #080
    font-weight: bold

  .rx 
    background-color: #fff0ff
    .k 
    color: #808
    .dl 
    color: #404
    .mod 
      color: #C2C
    .fu  
      color: #404
      font-weight: bold

  .s  
    background-color: #fff0f0
    .s 
      background-color: #ffe0e0
      .s 
        background-color: #ffd0d0
    .k 
    color: #D20
    .dl 
    color: #710

  .sh 
    background-color: #f0fff0
    .k 
      color: #2B2
    .dl 
      color: #161

  .sy 
    color: #A60
    .k 
      color: #A60
    .dl 
      color: #630

  .ta 
    color: #070
  .tf 
    color: #070
    font-weight: bold
  .ts 
    color: #D70
    font-weight: bold
  .ty 
    color: #339
    font-weight: bold
  .v  
    color: #036
  .xt 
    color: #444

span.CodeRay
  white-space: pre
  border: 0px
  padding: 2px

=numbers
  background-color: #def
  color: gray
  text-align: right

table.CodeRay 
  border-collapse: collapse
  width: 100%
  padding: 2px
  td
    padding: 2px 4px
    vertical-align: top
  .line_numbers
    +numbers
    tt
      font-weight: bold
  .no
    +numbers
    padding: 0px 4px

ol.CodeRay
  font-size: 10pt
  li
    white-space: pre
