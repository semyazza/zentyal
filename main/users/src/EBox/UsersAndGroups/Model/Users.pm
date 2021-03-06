# Copyright (C) 2008-2012 eBox Technologies S.L.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License, version 2, as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

package EBox::UsersAndGroups::Model::Users;

# Class: EBox::UsersAndGroups::Model::Users
#
#       This a class used as a proxy for the users stored in LDAP.
#       It is meant to improve the user experience when managing users,
#       but it's just an interim solution. An integral approach needs to
#       be done.
#
use EBox::Global;
use EBox::Gettext;
use EBox::Validate qw(:all);
use EBox::Model::Row;
use EBox::Exceptions::External;
use EBox::Exceptions::Internal;

use EBox::Types::Text;
use EBox::Types::Link;

use strict;
use warnings;

use base 'EBox::Model::DataTable';

sub new
{
    my $class = shift;
    my %parms = @_;

    my $self = $class->SUPER::new(@_);
    bless($self, $class);

    return $self;
}

sub _table
{
    my @tableHead =
    (
         new EBox::Types::Text(
             'fieldName' => 'name',
             'printableName' => __('Name'),
             'size' => '12',
             ),
         new EBox::Types::Text(
             'fieldName' => 'fullname',
             'printableName' => __('Full name'),
             'size' => '12',
             ),
         new EBox::Types::Link(
             'fieldName' => 'edit',
             'printableName' => __('Edit'),
             ),
    );

    my $dataTable =
    {
        'tableName' => 'Users',
        'printableTableName' => __('Users'),
        'defaultController' => '/Users/Controller/Users',
        'defaultActions' => ['changeView'],
        'tableDescription' => \@tableHead,
        'menuNamespace' => 'UsersAndGroups/Users',
        'printableRowName' => __('user'),
        'sortedBy' => 'name',
        'withoutActions' => 1,
    };

    return $dataTable;
}

sub Viewer
{
    return '/users/usersTableBody.mas';
}

# Method: precondition
#
# Check if the module is configured
#
# Overrides:
#
# <EBox::Model::DataTable::precondition>
sub precondition
{
    my ($self) = @_;
    my $users = EBox::Global->modInstance('users');
    unless ($users->configured()) {
        $self->{preconFail} = 'notConfigured';
        return undef;
    }

    unless (@{$self->ids()}) {
        $self->{preconFail} = 'noUsers';
        return undef;
    }

    return 1;
}

# Method: preconditionFailMsg
#
# Check if the module is configured
#
# Overrides:
#
# <EBox::Model::DataTable::precondition>
sub preconditionFailMsg
{
    my ($self) = @_;

    if ($self->{preconFail} eq 'notConfigured') {
        return __('You must enable the module Users in the module ' .
                'status section in order to use it.');
    } else {
        my $users = $self->parentModule();
        my $mode = $users->mode();
        if ($mode eq 'master') {
            return $self->noUsersMsg();
        } elsif ($mode eq 'slave') {
            my $master = $users->model('Mode')->remoteValue();
            return __x('Zentyal is configured as slave and there are no users at the moment. You may want to add some in the {openhref}master{closehref}.',
                       openhref => "<a href='https://$master/zentyal/UsersAndGroups/Users'>",
                       closehref => '</a>');
        } elsif ($mode eq 'ad-slave') {
            return __('Zentyal is configured as Windows AD slave and there are no users at the moment. If there are users in your Domain Controller, maybe the synchronization process has failed or has not finished yet.');
        }
    }
}

sub noUsersMsg
{
    my ($self) = @_;
    my $filterOU = $self->filterOU();
    if (not $filterOU) {
        return __x('There are no users at the moment');
    }

    return __x('There are no users for the organizational unit: {ou}<p>{ao}See users for all organizational units{ac}',
                ou => $filterOU,
                ao => q{<a href='/UsersAndGroups/Users'>},
                ac => q{</a>}
               );
}


my %kerberosUsers = (
    dns => 1,
    mail => 1,
    proxy => 1,
    zarafa => 1,

);
# Method: ids
#
#   Override <EBox::Model::DataTable::ids> to return rows identifiers
#   based on the users stored in LDAP
#
sub ids
{
    my ($self) = @_;
    my $global = $self->global();
    my $users = $global->modInstance('users');
    unless ($users->configured()) {
        return [];
    }

    my $hostname = $global->modInstance('sysinfo')->hostName();
    my $kerberosRe = qr/^([A-Za-z]+)-$hostname$/;
    my @list = map {
        my $user = $_;
        my $name = $user->name;
        my $isKerberos = 0;
        if ($name =~ $kerberosRe) {
            $isKerberos = exists $kerberosUsers{$1};
        }

        $isKerberos ? () : $user->dn()
    } @{$users->users()};

    my $filterOU = $self->filterOU();
    if ($filterOU) {
        my $filterRe = qr/,$filterOU$/;
        @list = grep {
            $_ =~ m/$filterRe/;
        } @list;
    }

    return \@list;
}

# Method: row
#
#   Override <EBox::Model::DataTable::row> to build and return a
#   row dependening on the user uid which is the id passwd.
#
sub row
{
    my ($self, $id) = @_;

    my $user = new EBox::UsersAndGroups::User(dn => $id);
    if ($user->exists()) {
        my $full = $user->get('cn');
        my $userName = $user->get('uid');
        my $link = "/UsersAndGroups/User?user=$id";
        my $row = $self->_setValueRow(
            name => $userName,
            fullname => $full,
            edit => $link,
        );
        $row->setId($id);
        $row->setReadOnly(1);
        return $row;
    } else {
        throw EBox::Exceptions::Internal("user $id does not exist");
    }
}


sub setFilterOU
{
    my ($self, $filter) = @_;
    $self->{filterOU} = $filter;
}

sub filterOU
{
    my ($self) = @_;
    if (not $self->parentModule()->multipleOusEnabled()) {
        return undef;
    }
    return $self->{filterOU};
}

1;
