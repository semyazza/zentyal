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

package EBox::UsersAndGroups::Model::Groups;

# Class: EBox::UsersAndGroups::Model::Groups
#
#       This a class used as a proxy for the groups stored in LDAP.
#       It is meant to improve the user experience when managing groups,
#       but it's just an interim solution. An integral approach needs to
#       be done.
#
use EBox::Global;
use EBox::Gettext;
use EBox::Validate qw(:all);
use EBox::Model::Row;
use EBox::Exceptions::External;
use EBox::UsersAndGroups::Group;

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
             'fieldName' => 'description',
             'printableName' => __('Description'),
             'size' => '30',
             ),
         new EBox::Types::Link(
             'fieldName' => 'edit',
             'printableName' => __('Edit'),
             ),

    );

    my $dataTable =
    {
        'tableName' => 'Groups',
        'printableTableName' => __('Groups'),
        'defaultController' => '/Users/Controller/Groups',
        'defaultActions' => ['changeView'],
        'tableDescription' => \@tableHead,
        'menuNamespace' => 'UsersAndGroups/Groups',
        'help' => '',
        'printableRowName' => __('group'),
        'sortedBy' => 'name',
        'withoutActions' => 1,
    };

    return $dataTable;
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
    my $usersMod = EBox::Global->modInstance('users');
    unless ($usersMod->configured()) {
        $self->{preconFail} = 'notConfigured';
        return undef;
    }

    unless (@{$usersMod->groups()}) {
        $self->{preconFail} = 'noGroups';
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
            return __x('There are no groups at the moment');
        } elsif ($mode eq 'slave') {
            my $master = $users->model('Mode')->remoteValue();
            return __x('Zentyal is configured as slave and there are no groups at the moment. You may want to add some in the {openhref}master{closehref}.',
                       openhref => "<a href='https://$master/zentyal/UsersAndGroups/Groups'>",
                       closehref => '</a>');
        } elsif ($mode eq 'ad-slave') {
            return __('Zentyal is configured as Windows AD slave and there are no groups at the moment. If there are groups in your Domain Controller, maybe the synchronization process has failed or has not finished yet.');
        }
    }
}

# Method: ids
#
#   Override <EBox::Model::DataTable::ids> to return rows identifiers
#   based on the groups stored in LDAP
#
sub ids
{
    my ($self) = @_;

    my $users = EBox::Global->modInstance('users');
    unless ($users->configured()) {
        return [];
    }

    my @list = map { $_->dn() } @{$users->groups()};
    return \@list;
}

# Method: row
#
#   Override <EBox::Model::DataTable::row> to build and return a
#   row dependening on the user gid which is the id passwd.
#
sub row
{
    my ($self, $id) = @_;

    my $group = new EBox::UsersAndGroups::Group(dn => $id);

    my $desc = $group->get('description');
    my $name = $group->get('cn');
    my $link = "/UsersAndGroups/Group?group=" . $group->dn();
    my $row = $self->_setValueRow(
                    name => $name,
                    description => defined($desc) ? $desc : '-',
                    edit => $link);
    $row->setId($id);
    $row->setReadOnly(1);
    return $row;
}

1;
