package PerldocBrowser::Plugin::PerldocSearchPg;

# This software is Copyright (c) 2018 Dan Book <dbook@cpan.org>.
# This is free software, licensed under:
#   The Artistic License 2.0 (GPL Compatible)

use 5.020;
use Mojo::Base 'Mojolicious::Plugin';
use List::Util 1.33 'all';
use Mojo::DOM;
use Mojo::File 'path';
use Mojo::Pg;
use Mojo::URL;
use Mojo::Util qw(url_unescape trim);
use experimental 'signatures';

sub register ($self, $app, $conf) {
  my $url = $app->config->{pg} // die "Postgresql connection must be configured in 'pg'\n";
  my $pg = Mojo::Pg->new($url);
  $pg->migrations->from_file($app->home->child('perldoc-browser.sql'))->migrate;
  $app->helper(pg => sub { $pg });

  $app->helper(index_perl_version => \&_index_perl_version);
  $app->helper(index_pod => \&_index_pod);
  $app->helper(index_functions => \&_index_functions);
  $app->helper(index_variables => \&_index_variables);
  $app->helper(index_faqs => \&_index_faqs);
  $app->helper(clear_index => \&_clear_index);

  my %defaults = (
    module => 'search',
    perl_version => $app->latest_perl_version,
    url_perl_version => '',
  );

  foreach my $perl_version (@{$app->all_perl_versions}) {
    $app->routes->any("/$perl_version/search" => {%defaults, perl_version => $perl_version, url_perl_version => $perl_version} => \&_search);
  }

  $app->routes->any('/search' => {%defaults} => \&_search);
}

sub _search ($c) {
  my $query = trim($c->param('q') // '');
  $c->stash(cpan => Mojo::URL->new('https://metacpan.org/search')->query(q => $query));

  my $url_perl_version = $c->stash('url_perl_version');
  my $url_prefix = $url_perl_version ? "/$url_perl_version" : '';

  my $function = _function_name_match($c, $query);
  return $c->redirect_to(Mojo::URL->new("$url_prefix/functions/")->path($function)) if defined $function;

  my $variable = _variable_name_match($c, $query);
  return $c->redirect_to(Mojo::URL->new("$url_prefix/variables/")->path($variable)) if defined $variable;

  my $digits = _digits_variable_match($c, $query);
  return $c->redirect_to(Mojo::URL->new("$url_prefix/variables/")->path($digits)) if defined $digits;

  my $pod = _pod_name_match($c, $query);
  return $c->redirect_to(Mojo::URL->new("$url_prefix/")->path($pod)) if defined $pod;

  my $function_results = _function_search($c, $query);
  my $faq_results = _faq_search($c, $query);
  my $pod_results = _pod_search($c, $query);

  my @paras = ('=encoding UTF-8');
  push @paras, '=head2 FAQ', '=over';
  if (@$faq_results) {
    foreach my $faq (@$faq_results) {
      my ($perlfaq, $question, $headline) = ($faq->{perlfaq}, map { $c->escape_pod($_) } @$faq{'question','headline'});
      $headline =~ s/__HEADLINE_START__/I<<< B<< /g;
      $headline =~ s/__HEADLINE_STOP__/ >> >>>/g;
      $headline =~ s/\n+/ /g;
      push @paras, qq{=item L<$perlfaq/"$question">\n\n$headline};
    }
  } else {
    push @paras, '=item I<No results>';
  }
  push @paras, '=back', '=head2 Functions', '=over';
  if (@$function_results) {
    foreach my $function (@$function_results) {
      my ($name, $headline) = map { $c->escape_pod($_) } @$function{'name','headline'};
      $headline =~ s/__HEADLINE_START__/I<<< B<< /g;
      $headline =~ s/__HEADLINE_STOP__/ >> >>>/g;
      $headline =~ s/\n+/ /g;
      push @paras, qq{=item L<perlfunc/"$name">\n\n$headline};
    }
  } else {
    push @paras, '=item I<No results>';
  }
  push @paras, '=back', '=head2 Documentation', '=over';
  if (@$pod_results) {
    foreach my $page (@$pod_results) {
      my ($name, $abstract, $headline) = map { $c->escape_pod($_) } @$page{'name','abstract','headline'};
      $headline =~ s/__HEADLINE_START__/I<<< B<< /g;
      $headline =~ s/__HEADLINE_STOP__/ >> >>>/g;
      $headline =~ s/\n+/ /g;
      push @paras, "=item L<$name> - $abstract\n\n$headline";
    }
  } else {
    push @paras, '=item I<No results>';
  }
  push @paras, '=back';
  my $src = join "\n\n", @paras;

  $c->respond_to(txt => {data => $src}, html => sub { $c->render_perldoc_html($src) });
}

sub _pod_name_match ($c, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "pods" WHERE "perl_version" = $1
    AND lower("name") = lower($2) ORDER BY "name" = $2 DESC, "name" LIMIT 1', $c->stash('perl_version'), $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _function_name_match ($c, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "functions" WHERE "perl_version" = $1
    AND lower("name") = lower($2) ORDER BY "name" = $2 DESC, "name" LIMIT 1', $c->stash('perl_version'), $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _variable_name_match ($c, $query) {
  my $match = $c->pg->db->query('SELECT "name" FROM "variables" WHERE "perl_version" = $1
    AND lower("name") = lower($2) ORDER BY "name" = $2 DESC, "name" LIMIT 1', $c->stash('perl_version'), $query)->arrays->first;
  return defined $match ? $match->[0] : undef;
}

sub _digits_variable_match ($c, $query) {
  return undef unless $query =~ m/^\$[1-9][0-9]*$/;
  my $match = $c->pg->db->query('SELECT "name" FROM "variables" WHERE "perl_version" = $1
    AND lower("name") LIKE lower($2) ORDER BY "name" LIMIT 1', $c->stash('perl_version'), '$<digits>%')->arrays->first;
  return defined $match ? $match->[0] : undef;
}

my $headline_opts = 'StartSel="__HEADLINE_START__", StopSel="__HEADLINE_STOP__", MaxWords=15, MinWords=10, MaxFragments=2';

sub _pod_search ($c, $query) {
  $query =~ tr!/.!  !; # postgres likes to tokenize foo.bar and foo/bar funny
  return $c->pg->db->query(q{SELECT "name", "abstract",
    ts_rank_cd("indexed", plainto_tsquery('english_tag', $1), 1) AS "rank",
    ts_headline('english_tag', "contents", plainto_tsquery('english_tag', $1), $2) AS "headline"
    FROM "pods" WHERE "perl_version" = $3 AND "indexed" @@ plainto_tsquery('english_tag', $1)
    ORDER BY "rank" DESC, "name" LIMIT 20}, $query, $headline_opts, $c->stash('perl_version'))->hashes;
}

sub _function_search ($c, $query) {
  $query =~ tr!/.!  !;
  return $c->pg->db->query(q{SELECT "name",
    ts_rank_cd("indexed", plainto_tsquery('english_tag', $1), 1) AS "rank",
    ts_headline('english_tag', "description", plainto_tsquery('english_tag', $1), $2) AS "headline"
    FROM "functions" WHERE "perl_version" = $3 AND "indexed" @@ plainto_tsquery('english_tag', $1)
    ORDER BY "rank" DESC, "name" LIMIT 20}, $query, $headline_opts, $c->stash('perl_version'))->hashes;
}

sub _faq_search ($c, $query) {
  $query =~ tr!/.!  !;
  return $c->pg->db->query(q{SELECT "perlfaq", "question",
    ts_rank_cd("indexed", plainto_tsquery('english_tag', $1), 1) AS "rank",
    ts_headline('english_tag', "answer", plainto_tsquery('english_tag', $1), $2) AS "headline"
    FROM "faqs" WHERE "perl_version" = $3 AND "indexed" @@ plainto_tsquery('english_tag', $1)
    ORDER BY "rank" DESC, "question" LIMIT 20}, $query, $headline_opts, $c->stash('perl_version'))->hashes;
}

sub _index_perl_version ($c, $perl_version, $pods, $index_pods = 1) {
  my $db = $c->pg->db;
  my $tx = $db->begin;
  $c->clear_index($db, $perl_version, 'functions') if exists $pods->{perlfunc};
  $c->clear_index($db, $perl_version, 'variables') if exists $pods->{perlvar};
  $c->clear_index($db, $perl_version, 'faqs') if all { exists $pods->{"perlfaq$_"} } 1..9;
  $c->clear_index($db, $perl_version, 'pods') if $index_pods;
  foreach my $pod (keys %$pods) {
    print "Indexing $pod for $perl_version ($pods->{$pod})\n";
    my $src = path($pods->{$pod})->slurp;
    $c->index_pod($db, $perl_version, $pod, $src) if $index_pods;
    if ($pod eq 'perlfunc') {
      print "Indexing functions for $perl_version\n";
      $c->index_functions($db, $perl_version, $src);
    } elsif ($pod eq 'perlvar') {
      print "Indexing variables for $perl_version\n";
      $c->index_variables($db, $perl_version, $src);
    } elsif ($pod =~ m/^perlfaq[1-9]$/) {
      print "Indexing $pod FAQs for $perl_version\n";
      $c->index_faqs($db, $perl_version, $pod, $src);
    }
  }
  $tx->commit;
}

sub _index_pod ($c, $db, $perl_version, $name, $src) {
  my %properties = (perl_version => $perl_version, name => $name, abstract => '', description => '', contents => '');

  unless ($name eq 'perltoc' or $name =~ m/^perlfaq/) {
    my $dom = Mojo::DOM->new($c->pod_to_html($src, undef, 0));
    my $headings = $dom->find('h1');

    my $name_heading = $headings->first(sub { trim($_->all_text) eq 'NAME' });
    my $name_para = $name_heading ? $name_heading->following('p')->first : undef;
    if (defined $name_para) {
      $properties{abstract} = trim($name_para->all_text);
      $properties{abstract} =~ s/.*?\s+-\s+//;
    }

    my $description_heading = $headings->first(sub { trim($_->all_text) eq 'DESCRIPTION' })
      // $headings->first(sub { my $t = trim($_->all_text); $t ne 'NAME' and $t ne 'SYNOPSIS' });
    my $description_para = $description_heading ? $description_heading->following('p')->first : undef;
    $properties{description} = trim($description_para->all_text) if $description_para;

    $properties{contents} = trim($dom->all_text);
  }

  $db->insert('pods', \%properties, {on_conflict => \['("perl_version","name")
    do update set "abstract"=EXCLUDED."abstract", "description"=EXCLUDED."description",
    "contents"=EXCLUDED."contents"']}
  );
}

sub _index_functions ($c, $db, $perl_version, $src) {
  my $blocks = $c->split_functions($src);
  my %functions;
  foreach my $block (@$blocks) {
    my ($list_level, $is_filetest, $indexed_name, %names) = (0);
    foreach my $para (@$block) {
      $list_level++ if $para =~ m/^=over/;
      $list_level-- if $para =~ m/^=back/;
      # 0: navigatable, 1: navigatable and returned in search results
      if (!$list_level and $para =~ m/^=item/) {
        my $heading = $c->pod_to_text_content("=over\n\n$para\n\n=back");
        if ($heading =~ m/^([-\w\/]+)/) {
          $names{"$1"} //= $indexed_name ? 0 : 1;
          $indexed_name = 1;
        }
        $names{"$1"} //= 0 if $heading =~ m/^([-\w]+)/;
        $is_filetest = 1 if $heading =~ m/^-X\b/;
      }
      do { $names{"$_"} //= 0 for $para =~ m/^\s+(-[a-zA-Z])\s/mg } if $is_filetest;
    }
    push @{$functions{$_}}, $names{$_} ? @$block : () for keys %names;
  }

  foreach my $function (keys %functions) {
    my $pod = join "\n\n", '=over', @{$functions{$function}}, '=back';
    my $description = $c->pod_to_text_content($pod);

    $db->insert('functions', {
      perl_version => $perl_version,
      name => $function,
      description => $description,
    }, {on_conflict => \['("perl_version","name") do update set
      "description"=EXCLUDED."description"']}
    );
  }
}

sub _index_variables ($c, $db, $perl_version, $src) {
  my $blocks = $c->split_variables($src);
  my %variables;
  foreach my $block (@$blocks) {
    my ($list_level, %names) = (0);
    foreach my $para (@$block) {
      $list_level++ if $para =~ m/^=over/;
      $list_level-- if $para =~ m/^=back/;
      # 0: navigatable, 1: navigatable and returned in search results
      if (!$list_level and $para =~ m/^=item/) {
        my $heading = $c->pod_to_text_content("=over\n\n$para\n\n=back");
        $names{"$1"} = 0 if $heading =~ m/^([\$\@%].+)$/ or $heading =~ m/^([a-zA-Z]+)$/;
      }
    }
    push @{$variables{$_}}, $names{$_} ? @$block : () for keys %names;
  }

  foreach my $variable (keys %variables) {
    my $pod = join "\n\n", '=over', @{$variables{$variable}}, '=back';
    my $description = $c->pod_to_text_content($pod);

    $db->insert('variables', {
      perl_version => $perl_version,
      name => $variable,
    }, {on_conflict => \['("perl_version","name") do nothing']}
    );
  }
}

sub _index_faqs ($c, $db, $perl_version, $perlfaq, $src) {
  my $blocks = $c->split_faqs($src);
  my %faqs;
  foreach my $block (@$blocks) {
    my %questions;
    foreach my $para (@$block) {
      # 0: navigatable, 1: navigatable and returned in search results
      if ($para =~ m/^=head2/) {
        my $heading = $c->pod_to_text_content("=pod\n\n$para");
        $questions{$heading} = 1;
      }
    }
    push @{$faqs{$_}}, $questions{$_} ? @$block : () for keys %questions;
  }

  foreach my $question (keys %faqs) {
    my $answer = $c->pod_to_text_content(join "\n\n", '=pod', @{$faqs{$question}});

    $db->insert('faqs', {
      perl_version => $perl_version,
      perlfaq => $perlfaq,
      question => $question,
      answer => $answer,
    }, {on_conflict => \['("perl_version","perlfaq","question") do update set
      "answer"=EXCLUDED."answer"']}
    );
  }
}

sub _clear_index ($c, $db, $perl_version, $type) {
  $db->delete($type, {perl_version => $perl_version});
}

1;
