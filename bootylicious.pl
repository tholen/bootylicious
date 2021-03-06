#!/usr/bin/env perl

BEGIN { use FindBin; use lib "$FindBin::Bin/mojo/lib" }

use Mojolicious::Lite;
use Mojo::Date;
use Mojo::ByteStream;
use Mojo::Loader;
use Pod::Simple::HTML;
require Time::Local;
require File::Basename;
use Mojo::ByteStream 'b';

my %config = (
    author => $ENV{BOOTYLICIOUS_AUTHOR} || 'whoami',
    email  => $ENV{BOOTYLICIOUS_EMAIL}  || '',
    title  => $ENV{BOOTYLICIOUS_TITLE}  || 'Just another blog',
    about  => $ENV{BOOTYLICIOUS_ABOUT}  || 'Perl hacker',
    descr  => $ENV{BOOTYLICIOUS_DESCR}  || 'I do not know if I need this',
    articlesdir => $ENV{BOOTYLICIOUS_ARTICLESDIR} || 'articles',
    publicdir   => $ENV{BOOTYLICIOUS_PUBLICDIR}   || 'public',
    footer      => $ENV{BOOTYLICIOUS_FOOTER}
      || '<h1>bootylicious</h1> is powered by <em>Mojolicious::Lite</em> &amp;&amp; <em>Pod::Simple::HTML</em>',
    menu       => [],
    theme      => '',
    cuttag     => '[cut]',
    pagelimit => 10
);

my %hooks = (
    preinit  => [],
    init     => [],
    finalize => []
);

_read_config_from_file(\%config, app->home->rel_file('bootylicious.conf'));

_load_plugins($config{plugins});

_call_hook(app, 'preinit');

sub config {
    if (@_) {
        %config = (%config, @_);
    }

    return \%config;
}

sub index {
    my $c = shift;

    my $timestamp = $c->req->param('timestamp') || 0;

    my $article;
    my ($articles, $pager) =
      get_articles(limit => $config{pagelimit}, timestamp => $timestamp);

    my $last_modified;
    if (@$articles) {
        $article = $articles->[0];

        $last_modified = $article->{mtime};

        return 1 unless _is_modified($c, $last_modified);
    }

    my $later = 0;

    $c->stash(
        config   => \%config,
        article  => $article,
        articles => $articles,
        pager    => $pager
    );

    $c->res->headers->header('Last-Modified' => Mojo::Date->new($last_modified));

    $c->stash(template => 'index');

    $c->render;

    _call_hook($c, 'finalize');
}

get '/' => \&index => 'root';
get '/index' => \&index => 'index';

get '/archive' => sub {
    my $c = shift;

    my $root = $c->app->home;

    my $last_modified = Mojo::Date->new;

    my ($articles) = get_articles(limit => 0);
    if (@$articles) {
        $last_modified = $articles->[0]->{mtime};

        return 1 unless _is_modified($c, $last_modified);
    }

    $c->res->headers->header('Last-Modified' => $last_modified);

    $c->stash(
        articles      => $articles,
        last_modified => $last_modified,
        config        => \%config
    );

    $c->render;

    _call_hook($c, 'finalize');
} => 'archive';

get '/tags/:tag' => sub {
    my $c = shift;

    my $tag = $c->stash('tag');

    my ($articles) = get_articles(limit => 0);

    $articles = [
        grep {
            grep {/^$tag$/} @{$_->{tags}}
          } @$articles
    ];

    my $last_modified = Mojo::Date->new;
    if (@$articles) {
        $last_modified = $articles->[0]->{mtime};

        return 1 unless _is_modified($c, $last_modified);
    }

    $c->stash(
        config        => \%config,
        articles      => $articles,
        last_modified => $last_modified
    );

    $c->res->headers->header('Last-Modified' => Mojo::Date->new($last_modified));

    if ($c->stash('format') && $c->stash('format') eq 'rss') {
        $c->stash(template => 'index');
    }

    $c->render;

    _call_hook($c, 'finalize');
} => 'tag';

get '/tags' => sub {
    my $c = shift;

    my $tags = get_tags();

    $c->stash(config => \%config, tags => $tags);

    $c->render;

    _call_hook($c, 'finalize');
} => 'tags';

get '/articles/:year/:month/:alias' => sub {
    my $c = shift;

    my $articleid =
      $c->stash('year') . '/' . $c->stash('month') . '/' . $c->stash('alias');

    my $article = get_article($articleid);
    return $c->app->static->serve_404($c) unless $article;

    return 1 unless _is_modified($c, $article->{mtime});

    $c->stash(article => $article, template => 'article', config => \%config);

    $c->res->headers->header(
        'Last-Modified' => Mojo::Date->new($article->{mtime}));

    $c->render;

    _call_hook($c, 'finalize');
} => 'article';

sub theme {
    my $publicdir = app->home->rel_dir($config{publicdir});

    # CSS, JS auto import
    foreach my $type (qw/css js/) {
        $config{$type} =
          [map { s/^$publicdir\///; $_ }
              glob("$publicdir/bootylicious/themes/$config{theme}/*.$type")];
    }
}

sub _read_config_from_file {
    my ($config, $conf_file) = @_;
    if (-e $conf_file) {
        if (open FILE, "<", $conf_file) {
            my @lines = <FILE>;
            close FILE;

            foreach my $line (@lines) {
                chomp $line;
                next unless $line;
                next if $line =~ m/^#/;
                $line =~ s/^([^=]+)=//;
                my ($key, $value) = ($1, $line);
                $key =~ s/^BOOTYLICIOUS_//;
                $key = lc $key;

                if ($key eq 'menu') {
                    my @links = split(',', $value);
                    $config->{$key} = [];
                    foreach my $link (@links) {
                        $link =~ s/^([^:]+)://;
                        push @{$config->{$key}}, ($1 => $link);
                    }
                }
                elsif ($key eq 'perl5lib') {
                    unshift @INC, $_ for split(',', $value);
                }
                else {
                    $config->{$key} = $value;
                }
            }
        }
    }

    _decode_config($config);

    $ENV{SCRIPT_NAME} = $config{base} if $config{base};
}

sub _decode_config {
    my $config = shift;

    foreach my $key (keys %config) {
        if (ref $config->{$key}) {
            _decode_config_arrayref($config->{$key});
        }
        else {
            $config->{$key} = _decode_config_scalar($config->{$key});
        }
    }
}

sub _decode_config_scalar {
    return b($_[0])->decode('utf8')->to_string
}

sub _decode_config_arrayref {
    $_ = b($_)->decode('utf8')->to_string for @{$_[0]};
}

sub _load_plugins {
    my $plugin_names = shift;
    return unless $plugin_names;

    my @plugins = split(',', $plugin_names);
    return unless @plugins;

    my $lib_dir = app->home->rel_dir('lib');
    push @INC, $lib_dir;

    my $loader = Mojo::Loader->new;
    foreach my $plugin (@plugins) {
        my ($class, @args) = split(':', $plugin);
        $class = Mojo::ByteStream->new($class)->camelize;
        $class = "Bootylicious::Plugin::$class";

        app->log->debug("Loading plugin '$class'");

        if (my $e = $loader->load($class)) {
            next unless ref $e;

            app->log->error($e);
            next;
        }

        unless ($class->can('new')) {
            app->log->error(qq|Can't locate object method "new" via plugin '$class'|);
            next;
        }

        @args = map { split m/=/ } @args;
        my $instance = $class->new(@args);

        foreach my $hook (keys %hooks) {
            next unless $class->can("hook_$hook");

            app->log->debug("Registering hook '$class\::hook_$hook'");

            push @{$hooks{$hook}}, $instance;
        }
    }
}

sub _call_hook {
    my $c = shift;
    my $hook = shift;

    my $method = "hook_$hook";
    $_->$method($c) foreach @{$hooks{$hook}};
}

sub _is_modified {
    my $c = shift;
    my ($last_modified) = @_;

    my $date = $c->req->headers->header('If-Modified-Since');
    return 1 unless $date;

    return 1 unless Mojo::Date->new($date)->epoch == $last_modified->epoch;

    $c->res->code(304);
    $c->stash(rendered => 1);

    return 0;
}

sub get_tags {
    my $tags = {};

    my ($articles) = get_articles(limit => 0);

    foreach my $article (@$articles) {
        foreach my $tag (@{$article->{tags}}) {
            $tags->{$tag}->{count} ||= 0;
            $tags->{$tag}->{count}++;
        }
    }

    return $tags;
}

sub get_articles {
    my %params = @_;
    $params{limit} ||= 0;

    my $root =
      ($config{articlesdir} =~ m/^\//)
      ? $config{articlesdir}
      : app->home->rel_dir($config{articlesdir});

    my $pager = {};

    my @files = sort { $b cmp $a } glob($root . '/*.*');

    if ($params{limit}) {
        my $min = 0;

        if ($params{timestamp}) {
            my $i = 0;
            foreach my $file (@files) {
                $file =~ m/\/([^\/]+)-/;

                if ($1 le $params{timestamp}) {
                    $min = $i;
                    last;
                }

                $i++;
            }
        }

        my $max = $min + $params{limit};

        if ($min > $params{limit} - 1 && $files[$min - $params{limit}]) {
            $pager->{prev} = $1
              if File::Basename::basename($files[$min - $params{limit}])
                  =~ m/([^\/]+)-/;
        }

        if ($max < scalar(@files) && $files[$max]) {
            $pager->{next} = $1
              if File::Basename::basename($files[$max]) =~ m/([^\/]+)-/;
        }

        @files = splice(@files, $min, $params{limit});
    }

    my @articles;
    foreach my $file (@files) {
        my $data = _parse_article($file);
        next unless $data && %$data;

        push @articles, $data;
    }

    return (\@articles, $pager);
}

sub get_article {
    my $articleid = shift;
    return unless $articleid;

    my ($year, $month, $alias) = split('/', $articleid);
    return unless $year && $month && $alias;

    my $root =
      ($config{articlesdir} =~ m/^\//)
      ? $config{articlesdir}
      : app->home->rel_dir($config{articlesdir});

    my ($format) = ($articleid =~ s/\.([^\.]+)$//);
    $format ||= 'pod';

    my @files =
      glob( $root . '/'
          . $year
          . $month . '*-'
          . $alias
          . ".$format");

    if (@files > 1) {
        app->log->warn('More then one articles is available '
              . 'at the same year/month and name');
    }
    my $path = $files[0];
    return unless $path && -r $path;

    return _parse_article($path);
}

my %_articles;
my %_parsers;

sub _parse_article {
    my $path = shift;

    return unless $path;
    my $mtime   = Mojo::Date->new((stat($path))[9]);

    #return $_articles{$path} if $_articles{$path};

    unless ($path =~ m/\/(\d\d\d\d)(\d\d)(\d\d)(?:T(\d\d):?(\d\d):?(\d\d))?-(.*?)\.(.*)$/) {
        app->log->debug("Ignoring $path: unknown file");
        return;
    }
    my ($year, $month, $day, $hour, $minute, $second, $name, $ext) =
      ($1, $2, $3, $4, $5, $6, $7, $8);

    my $timestamp = "$1$2$3T$4:$5:$6";

    my $epoch = 0;
    eval {
        $epoch = Time::Local::timegm(
            $second || 0,
            $minute || 0,
            $hour   || 0,
            $day,
            $month - 1,
            $year - 1900
        );
    };
    if ($@ || $epoch < 0) {
        app->log->debug("Ignoring $path: wrong timestamp");
        return;
    }

    unless (open FILE, "<:encoding(UTF-8)", $path) {
        app->log->error("Can't open file: $path: $!");
        return;
    }
    my $string = join("", <FILE>);
    close FILE;

    my $created = Mojo::Date->new($epoch);

    my $parser = \&_parse_article_pod;
    if ($ext ne 'pod') {
        my $parser_class =
          'Bootylicious::Parser::' . Mojo::ByteStream->new($ext)->camelize;

        if ($_parsers{$parser_class}) {
            $parser = $_parsers{$parser_class};
        }
        else {
            eval "require $parser_class";
            if ($@) {
                app->log->error($@);
                return;
            }
            #my $loader = Mojo::Loader->new;
            #if (my $e = $loader->load($parser_class)) {
                #if (ref $e) {
                    #$c->app->log->error($e);
                #}
                #else {
                    #$c->app->log->error("Unknown parser: $parser_class");
                #}
                #return;
            #}

            $parser = $_parsers{$parser_class} = $parser_class->new->parser_cb;
        }
    }

    my $metadata = _parse_metadata(\$string);

    my $cuttag = $config{cuttag};
    my ($head, $tail) = ($string, '');
    my $preview_link = '';
    if ($head =~ s{(.*?)\Q$cuttag\E(?: (.*?))?(?:\n|\r|\n\r)(.*)}{$1}s) {
        $tail = $3;
        $preview_link = $2 || 'Keep reading';
    }

    my $data = $parser->($head, $tail);
    unless ($data) {
        app->log->debug("Ignoring $path: parser error");
        return;
    }

    my $content =
        $data->{tail}
      ? $data->{head} . '<a name="cut"></a>' . $data->{tail}
      : $data->{head};
    my $preview = $data->{tail} ? $data->{head} : '';

    return $_articles{$path} = {
        path           => $path,
        name           => $name,
        mtime          => $mtime,
        created        => $created,
        timestamp      => $timestamp,
        mtime_format   => _format_date($mtime),
        created_format => _format_date($created),
        year           => $year,
        month          => $month,
        day            => $day,
        hour           => $hour,
        minute         => $minute,
        second         => $second,
        title          => $metadata->{title} || $name,
        link           => $metadata->{link} || '',
        tags           => $metadata->{tags} || [],
        preview        => $preview,
        preview_link   => $preview_link,
        content        => $content
    };
}

sub _parse_metadata {
    my $string = shift;

    $$string =~ s/^(.*?)(?:\n\n|\n\r\n\r|\r\r)//s;
    return {} unless $1;

    my $data = $1;

    my $metadata = {};
    while ($data =~ s/^(.*?):\s*(.*?)(?:\n|\n\r|\r|$)//s) {
        my $key = lc $1;
        my $value = $2;

        if ($key eq 'tags') {
            my $tmp = $value || '';
            $value = [];
            @$value = map { s/^\s+//; s/\s+$//; $_ } split(/,/, $tmp);
        }

        $metadata->{$key} = $value;
    }

    return $metadata;
}

sub _parse_article_pod {
    my ($head_string, $tail_string) = @_;

    my $parser = Pod::Simple::HTML->new;

    $parser->force_title('');
    $parser->html_header_before_title('');
    $parser->html_header_after_title('');
    $parser->html_footer('');

    my $title = '';
    my $head  = '';
    my $tail  = '';

    $parser->output_string(\$head);
    $head_string = "=pod\n\n$head_string";
    eval { $parser->parse_string_document($head_string) };
    return if $@;

    # Hacking
    $head =~ s{<a name='___top' class='dummyTopAnchor'\s*></a>\n}{}g;
    $head =~ s{<a class='u'.*?name=".*?"\s*>(.*?)</a>}{$1}sg;
    $head =~ s{^\s*<h1>NAME</h1>\s*<p>(.*?)</p>}{}sg;
    $title = $1;

    if ($tail_string) {
        $tail_string = "=pod\n$tail_string";
        my $parser = Pod::Simple::HTML->new;

        $parser->force_title('');
        $parser->html_header_before_title('');
        $parser->html_header_after_title('');
        $parser->html_footer('');

        $parser->output_string(\$tail);
        eval { $parser->parse_string_document($tail_string) };
        return if $@;

        $tail =~ s{<a name='___top' class='dummyTopAnchor'\s*></a>\n}{}g;
        $tail =~ s{<a class='u'.*?name=".*?"\s*>(.*?)</a>}{$1}sg;
    }

    my $link = '';
    if ($head =~ s{^\s*<h1>LINK</h1>\s*<p>(.*?)</p>}{}sg) {
        $link = $1;
    }

    my $tags = [];
    if ($head =~ s{^\s*<h1>TAGS</h1>\s*<p>(.*?)</p>}{}sg) {
        my $list = $1; $list =~ s/(?:\r|\n)*//gs;
        @$tags = map { s/^\s+//; s/\s+$//; $_ } split(/,/, $list);
    }

    return {
        title => $title,
        link  => $link,
        tags  => $tags,
        head  => $head,
        tail  => $tail
    };
}

sub _format_date {
    my $date = shift;

    $date = $date->to_string;

    $date =~ s/ [^ ]*? GMT$//;

    return $date;
}

app->types->type(rss => 'application/rss+xml');

_call_hook(app, 'init');

theme;

shagadelic(@ARGV ? @ARGV : 'cgi');

__DATA__

@@ index.html.epl
% my $self = shift;
% my $articles = $self->stash('articles');
% my $pager = $self->stash('pager');
% $self->stash(layout => 'wrapper');
% foreach my $article (@{$articles}) {
    <div class="text">
        <h1 class="title"><%= '&raquo;' if $article->{link} %> <a
        href="<%= $article->{link} || $self->url_for('article', year => $article->{year}, month => $article->{month}, alias => $article->{name}, format => 'html') %>"><%= $article->{title} %></a></h1>
        <div class="created"><%= $article->{created_format} %></div>
        <div class="tags">
% foreach my $tag (@{$article->{tags}}) {
        <a href="<%= $self->url_for('tag', tag => $tag) %>"><%= $tag %></a>
% }
        </div>
% if ($article->{preview}) {
        <%= $article->{preview} %>
        <div class="more">&rarr; <a href="<%== $self->url_for('article', year => $article->{year}, month => $article->{month}, alias => $article->{name}) %>.html#cut"><%= $article->{preview_link} %></a></div>
% }
% else {
        <%= $article->{content} %>
% }
    </div>
% }

<div id="pager">
% if ($pager->{prev}) {
    &larr; <a href="<%= $self->url_for('index',format=>'html') %>?timestamp=<%= $pager->{prev} %>">Earlier</a>
% }
% else {
<span class="notactive">
&larr; Earlier
</span>
% }

% if ($pager->{next}) {
    <a href="<%= $self->url_for('index'),format=>'html' %>?timestamp=<%= $pager->{next} %>">Later</a> &rarr;
% }
% else {
<span class="notactive">
Later &rarr;
</span>
% }
</div>

@@ archive.html.epl
% my $self = shift;
% $self->stash(layout => 'wrapper');
% my $articles = $self->stash('articles');
% my $tmp;
% my $new = 0;
<div class="text">
<h1>Archive</h1>
<br />
% foreach my $article (@$articles) {
%     if (!$tmp || $article->{year} ne $tmp->{year}) {
    <%= "</ul>" if $tmp %>
    <b><%= $article->{year} %></b>
<ul>
%     }

    <li>
        <a href="<%== $self->url_for('article', year => $article->{year}, month => $article->{month}, alias => $article->{name}) %>"><%= $article->{title} %></a><br />
        <div class="created"><%= $article->{created_format} %></div>
    </li>

%     $tmp = $article;
% }
</div>

@@ index.rss.epl
% my $self = shift;
% my $articles = $self->stash('articles');
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xml:base="<%= $self->req->url->base %>"
    xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title><%= $self->stash('config')->{title} %></title>
        <link><%= $self->req->url->base %></link>
        <description><%= $self->stash('config')->{descr} %></description>
        <pubDate><%= $articles->[0]->{created} %></pubDate>
        <lastBuildDate><%= $articles->[0]->{created} %></lastBuildDate>
        <generator>Mojolicious::Lite</generator>
% foreach my $article (@$articles) {
% my $link = $self->url_for('article', year => $article->{year}, month => $article->{month}, alias => $article->{name}, format => 'html')->to_abs;
    <item>
      <title><%== $article->{title} %></title>
      <link><%= $link %></link>
% if ($article->{preview}) {
      <description><%== $article->{preview} %></description>
% }
% else {
      <description><%== $article->{content} %></description>
% }
% foreach my $tag (@{$article->{tags}}) {
      <category><%= $tag %></category>
% }
      <pubDate><%= $article->{created} %></pubDate>
      <guid><%= $link %></guid>
    </item>
% }
    </channel>
</rss>

@@ tags.html.epl
% my $self = shift;
% $self->stash(layout => 'wrapper');
% my $tags = $self->stash('tags');
<div class="text">
<h1>Tags</h1>
<br />
<div class="tags">
% foreach my $tag (keys %$tags) {
<a href="<%= $self->url_for('tag', tag => $tag, format => 'html') %>"><%= $tag %></a><sub>(<%= $tags->{$tag}->{count} %>)</sub>
% }
</div>
</div>

@@ tag.html.epl
% my $self = shift;
% $self->stash(layout => 'wrapper');
% my $tag = $self->stash('tag');
% my $articles = $self->stash('articles');
<div class="text">
<h1>Tag <%= $tag %>
<sup><a href="<%= $self->url_for('tag',tag=>$tag,format=>'rss') %>"><img src="data:image/png;base64,
iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJ
bWFnZVJlYWR5ccllPAAAAlJJREFUeNqkU0toU0EUPfPJtOZDm9gSPzWVKloXgiCCInXTRTZVQcSN
LtyF6qILFwoVV+7EjR9oFy7VlSAVF+ouqMWWqCCIrbYSosaARNGmSV7ee+OdyUsMogtx4HBn5t1z
7twz85jWGv8zZHaUmRjlHBnBkRYSCSnog/wzuECZMzxgDNPEW5E0ASHTl4qf6h+KD6iwUpwyuRCw
kcCCNSPoRsNZKeS31D8WTOHLkqoagbQhV+sV1fDqEJQoidSCCMiMjskZU9HU4AAJpJsC0gokTGVD
XnfhA0DRL7+Hn38M/foOeOUzOJEZs+2Cqy5F1iXs3PZLYEGl+ux1NF7eAmpfIXedQOjYbYgdh9tk
Y3oTsDAnNCewPZqF8/SKjdqs+7aCj5wFDkwSlUEvzFgyPK8twNvuBv3GzixgzfgcQmNXqW/68IgE
is+BvRPQ0fXE9eC7Lvy/Cfi5G8DSQ7DkTrCxKbrgJPSTS5TUDQwfgWvIBO0Dvv+bgPFAz12Dzl4E
7p5svpQ9p6HLy9DFF2CD+9sCHpG9DgHHeGAExDglZnLAj09APgts2N089pdFsPjmXwIuHAJk8JKL
rXtuDWtWtQwWiliScFapQJedKxKsVFA0KezVUeMvprcfHDkua6uRzqsylQ2hE2ZPqXAld+/tTfIg
I56VgNG1SDkuhmIb+3tELCLRTYYpRdVDFpwgCJL2fJfXFufLS4Xl6v3z7zBvXkdqUxjJc8M4tC2C
fdDoNe62XPaCaOEBVOjbm++YnSphpuSiZAR6CFQS4h//ZJJD7acAAwCdOg/D5ZiZiQAAAABJRU5E
rkJggg==" alt="RSS" /></a></sup>
</h1>
<br />
% foreach my $article (@$articles) {
        <a href="<%== $self->url_for('article', year => $article->{year}, month => $article->{month}, alias => $article->{name}) %>"><%= $article->{title} %></a><br />
        <div class="created"><%= $article->{created_format} %></div>
    </li>
% }
</div>

@@ article.html.epl
% my $self = shift;
% $self->stash(layout => 'wrapper');
% my $article = $self->stash('article');
<div class="text">
<h1 class="title">
% if ($article->{link}) {
&raquo; <a href="<%= $article->{link} %>"><%= $article->{title} %></a>
% } else {
<%= $article->{title} %>
% }
</h1>
<div class="created"><%= $article->{created_format} %>
% if ($article->{created} ne $article->{mtime}) {
, modified <span class="modified"><%= $article->{mtime_format} %></span>
% }
</div>
<div class="tags">
% foreach my $tag (@{$article->{tags}}) {
<a href="<%= $self->url_for('tag', tag => $tag, format => 'html') %>"><%= $tag %></a>
% }
</div>
<%= $article->{content} %>
</div>

@@ layouts/wrapper.html.epl
% my $self = shift;
% my $config = $self->stash('config');
% $self->res->headers->content_type('text/html; charset=utf-8');
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
    "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">

<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
    <head>
        <title><%= $config->{title} %></title>
        <meta http-equiv="Content-type" content="text/html; charset=utf-8" />
% foreach my $file (@{$config->{css}}) {
        <link rel="stylesheet" href="/<%= $file %>" type="text/css" />
% }
% if (!@{$config->{css}}) {
        <style type="text/css">
            body {background: #fff;font-family: "Helvetica Neue", Arial, Helvetica, sans-serif;}
            h1,h2,h3,h4,h5 {font-family: times, "Times New Roman", times-roman, georgia, serif; line-height: 40px; letter-spacing: -1px; color: #444; margin: 0 0 0 0; padding: 0 0 0 0; font-weight: 100;}
            a,a:active {color:#555}
            a:hover{color:#000}
            a:visited{color:#000}
            img{border:0px}
            pre{border:2px solid #ccc;background:#eee;padding:2em}
            #body {width:65%;margin:auto}
            #header {text-align:center;padding:2em 0em 0.5em 0em;border-bottom: 1px solid #000}
            h1#title{font-size:3em}
            h2#descr{font-size:1.5em;color:#999}
            span#author {font-weight:bold}
            span#about {font-style:italic}
            #menu {padding-top:1em;text-align:right}
            #content {background:#FFFFFF}
            .created, .modified {color:#999;margin-left:10px;font-size:small;font-style:italic;padding-bottom:0.5em}
            .modified {margin:0px}
            .tags{margin-left:10px;text-transform:uppercase;}
            .text {padding:2em;}
            .text h1.title {font-size:2.5em}
            .more {margin-left:10px}
            #pager {text-align:center;padding:2em}
            #pager span.notactive {color:#ccc}
            #subfooter {padding:2em;border-top:#000000 1px solid}
            #footer {font-size:80%;text-align:center;padding:2em;border-top:#000000 1px solid}
        </style>
% }
        <link rel="alternate" type="application/rss+xml" title="<%= $config->{title} %>" href="<%= $self->url_for('index', format => 'rss') %>" />
    </head>
    <body>
        <div id="body">
            <div id="header">
                <h1 id="title"><a href="<%= $self->url_for('root', format => '') %>"><%= $config->{title} %></a>
                <sup><a href="<%= $self->url_for('index', format=>'rss') %>"><img src="data:image/png;base64,
iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGXRFWHRTb2Z0d2FyZQBBZG9iZSBJ
bWFnZVJlYWR5ccllPAAAAlJJREFUeNqkU0toU0EUPfPJtOZDm9gSPzWVKloXgiCCInXTRTZVQcSN
LtyF6qILFwoVV+7EjR9oFy7VlSAVF+ouqMWWqCCIrbYSosaARNGmSV7ee+OdyUsMogtx4HBn5t1z
7twz85jWGv8zZHaUmRjlHBnBkRYSCSnog/wzuECZMzxgDNPEW5E0ASHTl4qf6h+KD6iwUpwyuRCw
kcCCNSPoRsNZKeS31D8WTOHLkqoagbQhV+sV1fDqEJQoidSCCMiMjskZU9HU4AAJpJsC0gokTGVD
XnfhA0DRL7+Hn38M/foOeOUzOJEZs+2Cqy5F1iXs3PZLYEGl+ux1NF7eAmpfIXedQOjYbYgdh9tk
Y3oTsDAnNCewPZqF8/SKjdqs+7aCj5wFDkwSlUEvzFgyPK8twNvuBv3GzixgzfgcQmNXqW/68IgE
is+BvRPQ0fXE9eC7Lvy/Cfi5G8DSQ7DkTrCxKbrgJPSTS5TUDQwfgWvIBO0Dvv+bgPFAz12Dzl4E
7p5svpQ9p6HLy9DFF2CD+9sCHpG9DgHHeGAExDglZnLAj09APgts2N089pdFsPjmXwIuHAJk8JKL
rXtuDWtWtQwWiliScFapQJedKxKsVFA0KezVUeMvprcfHDkua6uRzqsylQ2hE2ZPqXAld+/tTfIg
I56VgNG1SDkuhmIb+3tELCLRTYYpRdVDFpwgCJL2fJfXFufLS4Xl6v3z7zBvXkdqUxjJc8M4tC2C
fdDoNe62XPaCaOEBVOjbm++YnSphpuSiZAR6CFQS4h//ZJJD7acAAwCdOg/D5ZiZiQAAAABJRU5E
rkJggg==" alt="RSS" /></a></sup>

                </h1>
                <h2 id="descr"><%= $config->{descr} %></h2>
                <span id="author"><%= $config->{author} %></span>, <span id="about"><%= $config->{about} %></span>
                <div id="menu">
                    <a href="<%= $self->url_for('index', format => 'html') %>">index</a>
                    <a href="<%= $self->url_for('tags', format => 'html') %>">tags</a>
                    <a href="<%= $self->url_for('archive', format => 'html') %>">archive</a>
% for (my $i = 0; $i < @{$config->{menu}}; $i += 2) {
                    <a href="<%= $config->{menu}->[$i + 1] %>"><%= $config->{menu}->[$i] %></a>
% }
                </div>
            </div>

            <div id="content">
            <%= $self->render_inner %>
            </div>

            <div id="footer"><%= $config->{footer} %></div>
        </div>
% foreach my $file (@{$config->{js}}) {
        <script type="text/javascript" href="/<%= $file %>" />
% }
    </body>
</html>

__END__

=head1 NAME

Bootylicious -- one-file blog on Mojo steroids!

=head1 SYNOPSIS

    $ perl bootylicious.pl daemon

=head1 DESCRIPTION

Bootylicious is a minimalistic blogging application built on
L<Mojolicious::Lite>. You start with just one file, but it is easily extendable
when you add new templates, css files etc.

=head1 CONFIGURATION

=head1 FILESYSTEM

All the articles must be stored in BOOTYLICIOUS_ARTICLESDIR directory with a
name like 20090730-my-new-article.pod. They are parsed with
L<Pod::Simple::HTML>.

=head1 TEMPLATES

Embedded templates will work just fine, but when you want to have something more
advanced just create a template in templates/ directory with the same name but
with a different extension.

For example there is index.html.epl, thus templates/index.html.epl should be
created with a new content.

=head1 DEVELOPMENT

=head2 Repository

    http://github.com/vti/bootylicious/commits/master

=head1 SEE ALSO

L<Mojo> L<Mojolicious> L<Mojolicious::Lite>

=head1 AUTHOR

Viacheslav Tykhanovskyi, C<vti@cpan.org>.

=head1 COPYRIGHT

Copyright (C) 2008-2009, Viacheslav Tykhanovskyi.

This program is free software, you can redistribute it and/or modify it under
the same terms as Perl 5.10.

=cut
