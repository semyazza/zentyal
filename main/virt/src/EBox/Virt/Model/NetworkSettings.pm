# Copyright (C) 2011 eBox Technologies S.L.
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


package EBox::Virt::Model::NetworkSettings;

# Class: EBox::Virt::Model::NetworkSettings
#
#      Table with the network interfaces of the Virtual Machine
#

use base 'EBox::Model::DataTable';

use strict;
use warnings;

use EBox::Global;
use EBox::Gettext;
use EBox::Types::Boolean;
use EBox::Types::Select;

# Group: Public methods

# Constructor: new
#
#       Create the new NetworkSettings model.
#
# Overrides:
#
#       <EBox::Model::DataForm::new>
#
# Returns:
#
#       <EBox::Virt::Model::NetworkSettings> - the recently created model.
#
sub new
{
    my $class = shift;

    my $self = $class->SUPER::new(@_);

    bless ($self, $class);

    return $self;
}

# Group: Private methods


sub _populateIfaceTypes
{
    return [
            { value => 'nat', printableValue => 'NAT' },
            { value => 'bridged', printableValue => __('Bridged') },
    ];
}

# Method: _table
#
# Overrides:
#
#      <EBox::Model::DataTable::_table>
#
sub _table
{
    my @tableHeader = (
       new EBox::Types::Select(
                               fieldName     => 'type',
                               printableName => __('Type'),
                               populate      => \&_populateIfaceTypes,
                               unique        => 0,
                               editable      => 1,
                              ),
    );

    my $dataTable =
    {
        tableName          => 'NetworkSettings',
        printableTableName => __('Network Settings'),
        printableRowName   => __('interface'),
        defaultActions     => [ 'add', 'del', 'editField', 'changeView' ],
        tableDescription   => \@tableHeader,
        enableProperty     => 1,
        class              => 'dataTable',
        help               => __('Here you can define the network interfaces of the virtual machine'),
        modelDomain        => 'Virt',
    };

    return $dataTable;
}

# FIXME: Workaround for the composite-children-of-submodel bug
sub parentRow
{
    my ($self) = @_;

    my $parent = $self->parent();
    return $parent ? $parent->parentRow() : undef;
}

1;