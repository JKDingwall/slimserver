package Slim::Schema::Contributor;


use strict;
use base 'Slim::Schema::DBI';

use List::Util qw(max);

use Slim::Schema::ResultSet::Contributor;

use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;

use constant MIN_CUSTOM_ROLE_ID => 21;

my %contributorToRoleMap;
my @contributorRoles;
my @contributorRoleIds;
my $totalContributorRoles;
my %roleToContributorMap;
my @defaultContributorRoles;
my @userDefinedRoles;
my @activeUserDefinedRoles;
my @albumLinkUserDefinedRoles;
my @activeAndAlbumLinkUserDefinedRoles;
my @allAlbumLinkRoles;
my @inArtistsRoles;

my $prefs = preferences('server');

initializeRoles();

{
	my $class = __PACKAGE__;

	$class->table('contributors');

	$class->add_columns(qw(
		id
		name
		namesort
		musicmagic_mixable
		namesearch
		musicbrainz_id
		extid
	));

	$class->set_primary_key('id');
	$class->add_unique_constraint('namesearch' => [qw/namesearch/]);

	$class->has_many('contributorTracks' => 'Slim::Schema::ContributorTrack');
	$class->has_many('contributorAlbums' => 'Slim::Schema::ContributorAlbum');

	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();

	$class->many_to_many('tracks', 'contributorTracks' => 'contributor', undef, {
		'distinct' => 1,
		'order_by' => ['disc', 'tracknum', "titlesort $collate"], # XXX won't change if language changes
	});

	$class->many_to_many('albums', 'contributorAlbums' => 'album', undef, { 'distinct' => 1 });

	if ($] > 5.007) {
		$class->utf8_columns(qw/name namesort/);
	}

	$class->resultset_class('Slim::Schema::ResultSet::Contributor');
}

sub initializeRoles {
	%contributorToRoleMap = (
		'ARTIST'      => 1,
		'COMPOSER'    => 2,
		'CONDUCTOR'   => 3,
		'BAND'        => 4,
		'ALBUMARTIST' => 5,
		'TRACKARTIST' => 6,
	);

	while ( my ($k, $v) = each %{ $prefs->get('userDefinedRoles') } ) {
		$contributorToRoleMap{$k} ||= $v->{id};
	}

	@contributorRoles = sort keys %contributorToRoleMap;
	@contributorRoleIds = values %contributorToRoleMap;
	$totalContributorRoles = scalar @contributorRoles;
	%roleToContributorMap = reverse %contributorToRoleMap;
	@defaultContributorRoles = grep { __PACKAGE__->isDefaultContributorRole($_) } contributorRoles();

	# de-reference the pref so we don't accidentally change it below
	my %udr = %{$prefs->get('userDefinedRoles')};
	(@userDefinedRoles, @activeUserDefinedRoles, @albumLinkUserDefinedRoles, @activeAndAlbumLinkUserDefinedRoles) = ();
	foreach my $role ( @contributorRoles ) {
		if ( __PACKAGE__->typeToRole($role) >= MIN_CUSTOM_ROLE_ID ) {
			push @userDefinedRoles, $role;
			push @activeUserDefinedRoles, $role if $udr{$role}->{include};
			push @albumLinkUserDefinedRoles, $role if $udr{$role}->{albumLink};
			push @activeAndAlbumLinkUserDefinedRoles, $role if $udr{$role}->{include} && $udr{$role}->{albumLink};
		}
	}

	@allAlbumLinkRoles = ( grep( { $prefs->get(lc($_) . 'AlbumLink') } contributorRoles() ), @albumLinkUserDefinedRoles );
	@inArtistsRoles = grep { $prefs->get(lc($_) . 'InArtists') } contributorRoles();
}

sub contributorRoles {
	return @contributorRoles;
}

sub isDefaultContributorRole {
	my $class = shift;
	my $role = shift;

	return $class->typeToRole($role) < MIN_CUSTOM_ROLE_ID;
}

sub defaultContributorRoles {
	return @defaultContributorRoles;
}

sub splitDefaultAndCustomRoles {
	my $class = shift;
	my $roles = shift;

	my @roles = split(',', $roles || '');
	my @defaultRoles;
	my @userDefinedRoles;

	foreach my $role (@roles) {
		if ( __PACKAGE__->isDefaultContributorRole($role) ) {
			push @defaultRoles, $role;
		} else {
			push @userDefinedRoles, $role;
		}
	}
	return (join(',', @defaultRoles), join(',', @userDefinedRoles));
}

sub userDefinedRoles {
	my $class = shift;
	my $activeOnly = shift;
	my $albumLink = shift;

	return @activeAndAlbumLinkUserDefinedRoles if $activeOnly && $albumLink;
	return @activeUserDefinedRoles if $activeOnly;
	return @albumLinkUserDefinedRoles if $albumLink;
	return @userDefinedRoles;
}

sub activeContributorRoles {
	my $class = shift;
	my $includeTrackArtist = shift;
	my $noUserRoles = shift;

	my @roles = ( 'ARTIST', 'ALBUMARTIST' );
	push @roles, 'TRACKARTIST' if $includeTrackArtist && !$prefs->get('trackartistInArtists');

	# Return roles that the user wants to show. Also include user-defined roles.
	push @roles, @inArtistsRoles;
	push @roles, __PACKAGE__->userDefinedRoles(1) unless $noUserRoles;

	return grep { $_ } @roles;
}

sub allAlbumLinkRoles {
	return @allAlbumLinkRoles;
}

sub contributorRoleIds {
	return @contributorRoleIds;
}

sub totalContributorRoles {
	return $totalContributorRoles;
}

sub roleToContributorMap {
	return \%roleToContributorMap;
}

sub typeToRole {
	return $contributorToRoleMap{$_[1]} || $_[1];
}

sub roleToType {
	return $roleToContributorMap{$_[1]};
}

sub getMinCustomRoleId {
	return max(MIN_CUSTOM_ROLE_ID, max(contributorRoleIds()) + 1);
}

sub extIds {
	my ($self) = @_;
	return [ split(',', $self->extid || '') ];
}

sub displayAsHTML {
	my ($self, $form, $descend, $sort) = @_;

	my $vaString = Slim::Music::Info::variousArtistString();

	$form->{'text'} = $self->name;

	if ($self->name eq $vaString) {
		$form->{'attributes'} .= "&album.compilation=1";
	}
}

# For saving favorites.
sub url {
	my $self = shift;

	return sprintf('db:contributor.name=%s', URI::Escape::uri_escape_utf8($self->name));
}

sub add {
	my $class = shift;
	my $args  = shift;

	# Pass args by name
	my $artist     = $args->{'artist'} || return;
	my $brainzID   = $args->{'brainzID'};

	my @contributors = ();

	# Bug 1955 - Previously 'last one in' would win for a
	# contributorTrack - ie: contributor & role combo, if a track
	# had an ARTIST & COMPOSER that were the same value.
	#
	# If we come across that case, force the creation of a second
	# contributorTrack entry.
	#
	# Split both the regular and the normalized tags
	my @artistList   = Slim::Music::Info::splitTag($artist);
	my @sortedList   = $args->{'sortBy'} ? Slim::Music::Info::splitTag($args->{'sortBy'}) : @artistList;

	my %artistToExtIdMap;
	@artistToExtIdMap{@artistList} = Slim::Music::Info::splitTag($args->{'extid'} || '');

	# Bug 9725, split MusicBrainz tag to support multiple artists
	my @brainzIDList;
	if ($brainzID) {
		@brainzIDList = Slim::Music::Info::splitTag($brainzID);
	}

	# Using native DBI here to improve performance during scanning
	my $dbh = Slim::Schema->dbh;

	for (my $i = 0; $i < scalar @artistList; $i++) {

		# Bug 10324, we now match only the exact name
		my $name   = $artistList[$i];
		my $extid  = $artistToExtIdMap{$name};
		my $search = Slim::Utils::Text::ignoreCase($name, 1);
		my $sort   = Slim::Utils::Text::ignoreCaseArticles(($sortedList[$i] || $name));
		my $mbid   = $brainzIDList[$i];
		my ($id, $oldExtId, $oldMbid, $sth);

		# check Musicbrainz ID first
		if ($mbid) {
			$sth = $dbh->prepare_cached( 'SELECT id, extid, musicbrainz_id FROM contributors WHERE musicbrainz_id = ?' );
			$sth->execute($mbid);
			($id, $oldExtId, $oldMbid) = $sth->fetchrow_array;
			$sth->finish;

			# no MBID found - try to merge with existing contributor of the same name for backwards compatibility
			if ( !$id ) {
				$sth = $dbh->prepare_cached( 'SELECT id, extid FROM contributors WHERE name = ? AND musicbrainz_id IS NULL' );
				$sth->execute($name);
				($id, $oldExtId) = $sth->fetchrow_array;
				$sth->finish;
			}
		}
		else {
			$sth = $dbh->prepare_cached( 'SELECT id, extid, musicbrainz_id FROM contributors WHERE name = ? LIMIT 1' );
			$sth->execute($name);
			($id, $oldExtId, $oldMbid) = $sth->fetchrow_array;
			$sth->finish;
		}

		if ( !$id ) {
			$sth = $dbh->prepare_cached( qq{
				INSERT INTO contributors
				(name, namesort, namesearch, musicbrainz_id, extid)
				VALUES
				(?, ?, ?, ?, ?)
			} );
			$sth->execute( $name, $sort, $search, $mbid, $extid );
			$id = $dbh->last_insert_id(undef, undef, undef, undef);
		}
		else {
			# Bug 3069: update the namesort only if it's different than namesearch
			if ( $search ne Slim::Utils::Unicode::utf8toLatin1Transliterate($sort) ) {
				$sth = $dbh->prepare_cached('UPDATE contributors SET namesort = ? WHERE id = ?');
				$sth->execute( $sort, $id );
			}

			# if we've found a contributor without Musicbrainz ID, merge for backwards compatibility
			if ( $mbid && $mbid ne $oldMbid ) {
				$sth = $dbh->prepare_cached('UPDATE contributors SET musicbrainz_id = ? WHERE id = ?');
				$sth->execute( $mbid, $id );
			}

			# allow adding external IDs from multiple services
			if ($extid) {
				my %uniqueIds = map {
					$_ => 1
				} split(',', $oldExtId || ''), $extid;
				my $newExtId = join(',', sort keys %uniqueIds);

				if ($newExtId ne $oldExtId) {
					$sth = $dbh->prepare_cached('UPDATE contributors SET extid = ? WHERE id = ?');
					$sth->execute( $newExtId, $id );
				}
			}
		}

		push @contributors, $id;
	}

	return wantarray ? @contributors : $contributors[0];
}

sub isInLibrary {
	my ( $self, $library_id ) = @_;

	return 1 unless $library_id && $self->id;
	return 1 if $library_id == -1;

	my $dbh = Slim::Schema->dbh;

	my $sth = $dbh->prepare_cached( qq{
		SELECT 1
		FROM library_contributor
		WHERE contributor = ?
		AND library = ?
		LIMIT 1
	} );

	$sth->execute($self->id, $library_id);
	my ($inLibrary) = $sth->fetchrow_array;
	$sth->finish;

	return $inLibrary;
}

# Rescan list of contributors, this simply means to make sure at least 1 track
# from this contributor still exists in the database.  If not, delete the contributor.
sub rescan {
	my ( $class, $ids, $albumId ) = @_;

	my $log = logger('scan.scanner');

	my $dbh = Slim::Schema->dbh;

	my $contributorSth = $dbh->prepare_cached( qq{
		SELECT COUNT(*) FROM contributor_track WHERE contributor = ?
	} );

	for my $id ( @$ids ) {
		$contributorSth->execute($id);
		my ($count) = $contributorSth->fetchrow_array;
		$contributorSth->finish;

		if ( !$count ) {
			main::DEBUGLOG && $log->is_debug && $log->debug("Removing unused contributor: $id");

			# This will cascade within the database to contributor_album and contributor_track
			$dbh->do( "DELETE FROM contributors WHERE id = ?", undef, $id );
		}
	}
}

1;

__END__
