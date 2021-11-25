import React from 'react'

import { v2 } from 'api'
import Content from 'components/Content'
import NodesList from './NodesList'
import { Resource, Node } from 'core/store/models'
import { SearchTextField } from 'src/components/Search/SearchTextField'
import { useErrorHandler } from 'hooks/useErrorHandler'
import { useLoadingPlaceholder } from 'hooks/useLoadingPlaceholder'

import Card from '@material-ui/core/Card'
import CardContent from '@material-ui/core/CardContent'
import Grid from '@material-ui/core/Grid'
import { Heading1 } from 'src/components/Heading/Heading1'

export type NodeResource = Resource<Node>

async function getNodes() {
  return Promise.all([v2.nodes.getNodes()]).then(([v2Nodes]) => {
    const nodesByDate = v2Nodes.data.sort(
      (a: NodeResource, b: NodeResource) => {
        const nodeA = new Date(a.attributes.createdAt).getTime()
        const nodeB = new Date(b.attributes.createdAt).getTime()
        return nodeA > nodeB ? -1 : 1
      },
    )

    return nodesByDate
  })
}

const searchIncludes = (searchParam: string) => {
  const lowerCaseSearchParam = searchParam.toLowerCase()

  return (stringToSearch: string) => {
    return stringToSearch.toLowerCase().includes(lowerCaseSearchParam)
  }
}

export const simpleNodeFilter = (search: string) => (node: NodeResource) => {
  if (search === '') {
    return true
  }

  return matchSimple(node, search)
}

// matchSimple does a simple match on the id, name, and EVM chain ID
function matchSimple(node: NodeResource, term: string) {
  const match = searchIncludes(term)

  const dataset: string[] = [
    node.id,
    node.attributes.name,
    node.attributes.evmChainID,
  ]

  return dataset.some(match)
}

export const NodesIndex = () => {
  const [search, setSearch] = React.useState('')
  const [nodes, setNodes] = React.useState<NodeResource[]>()
  const { error, ErrorComponent, setError } = useErrorHandler()
  const { LoadingPlaceholder } = useLoadingPlaceholder(!error && !nodes)

  React.useEffect(() => {
    document.title = 'Nodes'
  }, [])

  React.useEffect(() => {
    getNodes().then(setNodes).catch(setError)
  }, [setError])

  const nodeFilter = React.useMemo(
    () => simpleNodeFilter(search.trim()),
    [search],
  )

  return (
    <Content>
      <Grid container>
        <Grid item xs={9}>
          <Heading1>Nodes</Heading1>
        </Grid>

        <Grid item xs={12}>
          <ErrorComponent />
          <LoadingPlaceholder />
          <SearchTextField
            value={search}
            onChange={setSearch}
            placeholder="Search nodes"
          />
          {!error && nodes && (
            <Card>
              <CardContent>
                <NodesList nodes={nodes} nodeFilter={nodeFilter} />
              </CardContent>
            </Card>
          )}
        </Grid>
      </Grid>
    </Content>
  )
}

export default NodesIndex
