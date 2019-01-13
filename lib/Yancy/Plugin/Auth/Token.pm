package Yancy::Plugin::Auth::Token;
our $VERSION = '1.015';
# ABSTRACT: A simple token-based auth

=head1 SYNOPSIS

    use Mojolicious::Lite;
    plugin Yancy => {
        backend => 'sqlite://myapp.db',
        collections => {
            tokens => {
                properties => {
                    id => { type => 'integer', readOnly => 1 },
                    username => { type => 'string' },
                    token => { type => 'string' },
                },
            },
        },
    };
    app->yancy->plugin( 'Auth::Token' => {
        collection => 'tokens',
        username_field => 'username',
        token_field => 'token',
        token_digest => {
            type => 'SHA-1',
        },
    } );

=head1 DESCRIPTION

This plugin provides a basic token-based authentication scheme for
a site. Tokens are provided in the HTTP C<Authorization> header:

    Authorization: Token 

=head1 CONFIGURATION

This plugin has the following configuration options.

=head2 collection

The name of the Yancy collection that holds tokens. Required.

=head2 token_field

The name of the field to use for the token. Defaults to C<token>. The
token itself is meaningless except to authenticate a user. It must be
unique, and it should be treated like a password.

=head2 token_digest

This is the hashing mechanism that should be used for creating new
tokens via the L</add_token> helper. The default type is C<SHA-1>.

This value should be a hash of digest configuration. The one required
field is C<type>, and should be a type supported by the L<Digest> module:

=over

=item * MD5 (part of core Perl)

=item * SHA-1 (part of core Perl)

=item * SHA-256 (part of core Perl)

=item * SHA-512 (part of core Perl)

=back

Additional fields are given as configuration to the L<Digest> module.
Not all Digest types require additional configuration.

=head2 username_field

The name of the field in the collection which is the user's identifier.
This can be a user name, ID, or e-mail address, and is used to keep track
of who owns the token.

This field is optional. If not specified, no user name will be stored.

=head1 HELPERS

This plugin has the following helpers.

=head2 yancy.auth.current_user

Get the current user from the token, if any. Returns C<undef> if no token
was passed or the token was not found in the database.

    my $user = $c->yancy->auth->current_user
        || return $c->render( status => 401, text => 'Unauthorized' );

=head2 yancy.auth.add_token

    $ perl myapp.pl eval 'app->yancy->auth->add_token( "username" )'

Generate a new token and add it to the database. C<"username"> is the
username for the token. The token will be generated as a base-64 encoded
hash of the following input:

=over

=item * The username

=item * The site's L<secret|https://mojolicious.org/perldoc/Mojolicious#secrets>

=item * The current L<time|perlfunc/time>

=item * A random number

=back

=head1 SEE ALSO

L<Yancy::Plugin::Auth>

=cut

use Mojo::Base 'Mojolicious::Plugin';
use Yancy::Util qw( currym );
use Digest;

has collection =>;
has username_field =>;
has token_field =>;
has token_digest =>;
has plugin_field => undef;
has moniker => 'token';

sub register {
    my ( $self, $app, $config ) = @_;
    $self->init( $app, $config );
    $app->helper(
        'yancy.auth.current_user' => currym( $self, 'current_user' ),
    );
    $app->helper(
        'yancy.auth.add_token' => currym( $self, 'add_token' ),
    );
    $app->helper(
        'yancy.auth.check_cb' => currym( $self, 'check_cb' ),
    );
}

sub init {
    my ( $self, $app, $config ) = @_;
    my $coll = $config->{collection}
        || die "Error configuring Auth::Token plugin: No collection defined\n";
    die sprintf(
        q{Error configuring Auth::Token plugin: Collection "%s" not found}."\n",
        $coll,
    ) unless $app->yancy->config->{collections}{$coll};

    $self->collection( $coll );
    $self->username_field( $config->{username_field} );
    $self->token_field(
        $config->{token_field} || $config->{password_field} || 'token'
    );

    my $digest_type = delete $config->{token_digest}{type};
    if ( $digest_type ) {
        my $digest = eval {
            Digest->new( $digest_type, %{ $config->{token_digest} } )
        };
        if ( my $error = $@ ) {
            if ( $error =~ m{Can't locate Digest/${digest_type}\.pm in \@INC} ) {
                die sprintf(
                    q{Error configuring Auth::Token plugin: Token digest type "%s" not found}."\n",
                    $digest_type,
                );
            }
            die "Error configuring Auth::Token plugin: Error loading Digest module: $@\n";
        }
        $self->token_digest( $digest );
    }

    my $route = $config->{route} || $app->routes->any( '/yancy/auth/token' );
    $route->to( cb => currym( $self, 'check_token' ) );
}

sub current_user {
    my ( $self, $c ) = @_;
    return undef unless my $auth = $c->req->headers->authorization;
    return undef unless my ( $token ) = $auth =~ /^Token\ (\S+)$/;
    my $collection = $self->collection;
    my %search;
    $search{ $self->token_field } = $token;
    if ( my $field = $self->plugin_field ) {
        $search{ $field } = $self->moniker;
    }
    my @users = $c->yancy->list( $collection, \%search );
    if ( @users > 1 ) {
        die "Refusing to auth: Multiple users with the same token found";
        return undef;
    }
    return $users[0];
}

sub check_token {
    my ( $self, $c ) = @_;
    my $field = $self->username_field;
    if ( my $user = $self->current_user( $c ) ) {
        return $c->render(
            text => $field ? $user->{ $field } : 'Ok',
        );
    }
    return $c->render(
        status => 401,
        text => 'Unauthorized',
    );
}

sub login_form {
    # There is no login form for a token
    return undef;
}

sub add_token {
    my ( $self, $c, $username ) = @_;
    my @parts = ( $username, $c->app->secrets->[0], $$, scalar time, int rand 1_000_000 );
    my $token = $self->token_digest->clone->add( join "", @parts )->b64digest;
    my $username_field = $self->username_field;
    $c->yancy->create( $self->collection, {
        ( $username_field ? ( $username_field => $username ) : () ),
        $self->token_field => $token,
        ( $self->plugin_field ? ( $self->plugin_field => $self->moniker ) : () ),
    } );
    return $token;
}

sub check_cb {
    my ( $self, $c ) = @_;
    return sub {
        my ( $c ) = @_;
        $c->yancy->auth->current_user && return 1;
        $c->stash(
            template => 'yancy/auth/unauthorized',
            status => 401,
        );
        $c->respond_to(
            json => {},
            html => {},
        );
        return undef;
    };
}

1;
